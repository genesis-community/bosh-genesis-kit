package Genesis::Hook::Addon::BOSH::OpenbaoRotateSealKey v4.1.0;

use v5.20; # Genesis min perl version is 5.20
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info warning run/;
use Genesis::Term qw/in_controlling_terminal/;
use Genesis::UI qw/prompt_for_boolean/;
use Digest::SHA ();
use JSON::PP ();

# init - Initialize the hook {{{
sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
	$obj->{args} //= [];
	$obj->{options} = $obj->parse_options([
		'escrow-target=s',
		'skip-escrow',
		'yes|y',
	]);
	return $obj;
}

# }}}
# cmd_details - Documentation that is shown when running with --help {{{
sub cmd_details {
	return
		"Rotate the OpenBao static seal key, n-1 to n.\n".
		"  start [--escrow-target <safe target> | --skip-escrow]\n".
		"      Keep the current key and its id at openbao/seal/static-previous, ".
		"generate a new key at openbao/seal/static, and copy both to the escrow ".
		"vault, checked by hash.  Then deploy, check the openbao log, and restart ".
		"the job once.\n".
		"  finish [--yes]\n".
		"      Once the server has restarted on the new key, remove ".
		"openbao/seal/static-previous; deploy and restart again afterwards.\n".
		"  escrow --escrow-target <safe target>\n".
		"      Copy the current and previous keys to the escrow vault again, ".
		"checked by hash.\n".
		"  repair-id\n".
		"      Store the id derived from the previous key at ".
		"openbao/seal/static-previous:id.\n".
		"No key is printed, and none reaches a command line.";
}

# }}}
# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;
	my $env = $self->env;

	bail("#R{[ERROR]} Requires feature openbao")
		unless $env->has_feature('openbao');
	my $helpers = $self->openbao_seal_helpers;
	bail(
		"This environment uses the #c{%s} seal; only a static seal has a seal ".
		"key to rotate.", $helpers->openbao_seal_state($env)->{mode}
	) unless $helpers->openbao_seal_state($env)->{mode} eq 'static';

	my @args = @{$self->{args}};
	my $action = shift(@args) // '';
	bail("Unexpected argument(s): %s", join(' ', @args)) if @args;

	return $self->_start      if $action eq 'start';
	return $self->_finish     if $action eq 'finish';
	return $self->_escrow_all if $action eq 'escrow';
	return $self->_repair_id  if $action eq 'repair-id';
	bail(
		"Expected one of #c{start}, #c{finish}, #c{escrow}, or #c{repair-id}; see ".
		"#C{genesis %s do openbao-rotate-seal-key --help}.", $env->name
	);
}

# }}}
# _start - keep the current key as previous, then generate a new one {{{
#
# The order guarantees the old key is never lost: it is stored as previous
# (with the id the server derived for it) and escrowed before the new key
# is generated.  A run that stopped part way resumes here: when the
# previous key still equals the current one, nothing new was generated yet.
sub _start {
	my ($self) = @_;
	my $env     = $self->env;
	my $helpers = $self->openbao_seal_helpers;
	my $escrow  = $self->_escrow_choice;

	$self->_require_healthy_static_server;

	my $current = $self->_read_key('openbao/seal/static', 'current');
	my $previous = $helpers->openbao_vault_secret($env, 'openbao/seal/static-previous');
	if ($previous) {
		bail(
			"A rotation is already under way: #C{openbao/seal/static-previous} ".
			"holds a different key from the current one.  Deploy, restart the ".
			"openbao job, and run #C{genesis %s do openbao-rotate-seal-key finish}.  ".
			"To copy both keys to the escrow vault again, run the #c{escrow} action.",
			$env->name
		) unless defined($previous->{key}) && $previous->{key} eq $current;
		info("Resuming: the previous key is already stored and matches the current key.");
	}

	# Step 1: the outgoing key, with the id the release derived for it while
	# it was current.  The release never derives a previous id, so it is
	# stored beside the key for the previous-key overlay.
	my $id = $helpers->openbao_static_key_id($current);
	$self->_write('openbao/seal/static-previous', {key => $current, id => $id});
	my $check = $helpers->openbao_vault_secret($env, 'openbao/seal/static-previous');
	bail("Could not read back #C{openbao/seal/static-previous}; nothing else was changed.")
		unless $check && ($check->{key} // '') eq $current && ($check->{id} // '') eq $id;
	info("#G{Stored} the current key and its id (#C{%s}) at #C{openbao/seal/static-previous}.", $id);

	# Step 2: escrow the outgoing key before anything replaces it.
	$self->_escrow_path($escrow, 'openbao/seal/static-previous') if $escrow;

	# Step 3: the new key.  safe generates it, so it never passes through
	# this process or a command line.
	my $path = $env->secrets_base.'openbao/seal/static';
	my ($out, $rc, $err) = $self->vault->query(
		{redact_output => 1, stderr => 0},
		'gen', 64, '--policy', 'a-f0-9', $path, 'key'
	);
	bail("Could not generate a new seal key: %s", $err || $out || "safe exited $rc") if $rc;
	my $new = $self->_read_key('openbao/seal/static', 'new');
	bail(
		"The new seal key is the same as the previous one, so safe did not replace ".
		"it.  Nothing is rotated; the previous key is stored and escrowed, so run ".
		"#c{start} again."
	) if $new eq $current;
	info("#G{Generated} a new seal key at #C{openbao/seal/static}.");

	# Step 4: escrow the new key.
	$self->_escrow_path($escrow, 'openbao/seal/static') if $escrow;
	warning(
		"The seal keys were #R{not escrowed} (--skip-escrow).  Copy #C{%s} and ".
		"#C{%s} to the escrow vault before deploying.",
		$env->secrets_base.'openbao/seal/static',
		$env->secrets_base.'openbao/seal/static-previous'
	) unless $escrow;

	my $cmd = $env->get_call_path_with_env;
	info(
		"\nNext steps:\n".
		"[[  1. >>Deploy: #G{%s deploy}.  The manifest now carries both keys.  ".
		"On the unseal that follows, OpenBao decrypts with the previous key and ".
		"re-wraps its keys under the new one.\n".
		"[[  2. >>On the director, check the openbao log for a line that says ".
		"#C{post-unseal upgrade seal keys failed}.  If one appears, stop here; the ".
		"previous key must stay in place.\n".
		"[[  3. >>Restart the job once (#C{monit restart openbao}) and confirm it ".
		"comes back unsealed: #G{%s do openbao-status}.\n".
		"[[  4. >>Run #G{%s do openbao-rotate-seal-key finish}, deploy again, and ".
		"restart once more.\n",
		$cmd, $cmd, $cmd
	);
	return $self->done(1);
}

# }}}
# _finish - drop the previous key once the server runs on the new one {{{
sub _finish {
	my ($self) = @_;
	my $env     = $self->env;
	my $helpers = $self->openbao_seal_helpers;

	my $previous = $helpers->openbao_vault_secret($env, 'openbao/seal/static-previous');
	bail("No rotation is under way: #C{openbao/seal/static-previous} does not exist.")
		unless $previous;
	my $current = $self->_read_key('openbao/seal/static', 'current');
	bail(
		"The previous key is still the same as the current key, so #c{start} did ".
		"not finish.  Run #C{genesis %s do openbao-rotate-seal-key start} again.",
		$env->name
	) if ($previous->{key} // '') eq $current;

	$self->_require_healthy_static_server;

	info(
		"Removing the previous key is safe only when all of these are true:\n".
		"[[  - >>the environment was deployed with both keys,\n".
		"[[  - >>the openbao log has no #C{post-unseal upgrade seal keys failed} line, and\n".
		"[[  - >>the job was restarted once since that deploy and came back unsealed."
	);
	unless ($self->{options}{yes}) {
		bail("Confirm with #c{--yes} when running without a terminal.")
			unless in_controlling_terminal();
		prompt_for_boolean("Are all three true? [y|n] ", 0)
			or bail("Not removing the previous key.");
	}

	my ($out, $rc, $err) = $self->vault->query(
		{redact_output => 1, stderr => 0},
		'rm', '-f', $env->secrets_base.'openbao/seal/static-previous'
	);
	bail("Could not remove #C{openbao/seal/static-previous}: %s", $err || $out || "safe exited $rc") if $rc;
	bail("#C{openbao/seal/static-previous} still exists after removal.")
		if $helpers->openbao_vault_secret($env, 'openbao/seal/static-previous');

	my $cmd = $env->get_call_path_with_env;
	info(
		"#G{Removed} #C{openbao/seal/static-previous}.  Deploy (#G{%s deploy}) to drop ".
		"the previous key from the configuration, then restart the openbao job once ".
		"more.  Only after that restart comes back unsealed, remove the previous key ".
		"from the escrow vault (#C{safe -T <escrow> rm %s}).",
		$cmd, $env->secrets_base.'openbao/seal/static-previous'
	);
	return $self->done(1);
}

# }}}
# _escrow_all - copy both keys to the escrow vault again {{{
sub _escrow_all {
	my ($self) = @_;
	my $escrow = $self->_escrow_choice;
	bail("The #c{escrow} action needs #c{--escrow-target}.") unless $escrow;
	my $helpers = $self->openbao_seal_helpers;
	$self->_read_key('openbao/seal/static', 'current');
	$self->_escrow_path($escrow, 'openbao/seal/static');
	$self->_escrow_path($escrow, 'openbao/seal/static-previous')
		if $helpers->openbao_vault_secret($self->env, 'openbao/seal/static-previous');
	return $self->done(1);
}

# }}}
# _repair_id - store the id derived from the previous key {{{
sub _repair_id {
	my ($self) = @_;
	my $helpers = $self->openbao_seal_helpers;
	my $previous = $self->_read_key('openbao/seal/static-previous', 'previous');
	my $id = $helpers->openbao_static_key_id($previous);
	$self->_write('openbao/seal/static-previous', {key => $previous, id => $id});
	my $check = $helpers->openbao_vault_secret($self->env, 'openbao/seal/static-previous');
	bail("Could not read back #C{openbao/seal/static-previous}.")
		unless $check && ($check->{id} // '') eq $id && ($check->{key} // '') eq $previous;
	info(
		"#G{Stored} id #C{%s} at #C{openbao/seal/static-previous:id}.  Copy it to the ".
		"escrow vault with the #c{escrow} action.", $id
	);
	return $self->done(1);
}

# }}}
# _escrow_choice - the escrow target, or undef for --skip-escrow {{{
sub _escrow_choice {
	my ($self) = @_;
	my $target = $self->{options}{'escrow-target'};
	my $skip   = $self->{options}{'skip-escrow'};
	bail("Pass either #c{--escrow-target} or #c{--skip-escrow}, not both.") if $target && $skip;
	return undef if $skip;
	bail(
		"Name the escrow vault with #c{--escrow-target <safe target>}, or pass ".
		"#c{--skip-escrow} to rotate without an escrow copy."
	) unless $target;
	my $own = eval { $self->vault->name } // '';
	bail("The escrow target must be a different vault from the one this environment deploys from.")
		if $own ne '' && $target eq $own;
	return $target;
}

# }}}
# _require_healthy_static_server - unsealed, static, and not migrating {{{
sub _require_healthy_static_server {
	my ($self) = @_;
	my $env     = $self->env;
	my $helpers = $self->openbao_seal_helpers;
	my $ca_file = $helpers->openbao_ca_file($env, eval { $self->vault });
	my $s = $helpers->openbao_seal_status($env, ca_file => $ca_file)
		or bail("Cannot read #C{sys/seal-status}; rotate only while OpenBao is up.");
	bail("OpenBao has a seal migration pending; finish or back it out before rotating.")
		if $s->{migration};
	bail("OpenBao reports a #c{%s} seal, not static.", $s->{type} // 'unknown')
		unless ($s->{type} // '') eq 'static';
	bail("OpenBao is sealed; bring it back before rotating.") if $s->{sealed};
	return 1;
}

# }}}
# _read_key - read and validate a stored key, never printing it {{{
sub _read_key {
	my ($self, $relpath, $label) = @_;
	my $helpers = $self->openbao_seal_helpers;
	my $data = $helpers->openbao_vault_secret($self->env, $relpath);
	bail("The %s seal key at #C{%s:key} is not in the vault.", $label, $relpath)
		unless $data && defined($data->{key});
	if (my $problem = $helpers->openbao_static_key_problem($data->{key})) {
		bail("The %s seal key at #C{%s:key} is unusable because %s.", $label, $relpath, $problem);
	}
	return $data->{key};
}

# }}}
# _write - replace a secret in the deploying vault through stdin {{{
sub _write {
	my ($self, $relpath, $data) = @_;
	my $path = ($self->env->secrets_base.$relpath) =~ s{^/+}{}r;
	my $json = JSON::PP->new->canonical->encode({$path => $data});
	my ($out, $rc, $err) = $self->vault->query(
		{stdin => $json, redact_output => 1, stderr => 0}, 'import'
	);
	bail("Could not write #C{%s}: %s", $relpath, $err || $out || "safe exited $rc") if $rc;
	return 1;
}

# }}}
# _escrow_path - copy one secret to the escrow vault and verify by hash {{{
# The export travels in memory from one safe process to the other on
# stdin; the two copies are compared by SHA-256 so neither is printed.
sub _escrow_path {
	my ($self, $target, $relpath) = @_;
	my $path = ($self->env->secrets_base.$relpath) =~ s{^/+}{}r;
	my $json = JSON::PP->new->canonical;

	my ($out, $rc, $err) = $self->vault->query(
		{redact_output => 1, stderr => 0}, 'export', $path
	);
	bail("Could not export #C{%s} for escrow: %s", $relpath, $err || "safe exited $rc") if $rc;
	my $source = eval { $json->decode($out)->{$path} };
	bail("The export of #C{%s} did not hold it.", $relpath) unless ref($source) eq 'HASH';

	my $payload = $json->encode({$path => $source});
	(undef, $rc, $err) = run(
		{stdin => $payload, redact_output => 1, stderr => 0, env => {SAFE_TARGET => $target}},
		'safe', '-T', $target, 'import'
	);
	bail("Could not import #C{%s} into the escrow vault #C{%s}: %s", $relpath, $target, $err // "safe exited $rc") if $rc;

	($out, $rc, $err) = run(
		{redact_output => 1, stderr => 0, env => {SAFE_TARGET => $target}},
		'safe', '-T', $target, 'export', $path
	);
	my $copy = $rc ? undef : eval { $json->decode($out)->{$path} };
	my $want = Digest::SHA::sha256_hex($json->encode($source));
	my $got  = ref($copy) eq 'HASH' ? Digest::SHA::sha256_hex($json->encode($copy)) : '';
	bail(
		"The escrow copy of #C{%s} in #C{%s} does not match the original (compared ".
		"by SHA-256).  Stop and copy it by hand before going further.", $relpath, $target
	) unless $got eq $want;
	info("#G{Escrowed} #C{%s} in #C{%s} (SHA-256 match).", $relpath, $target);
	return 1;
}

# }}}
# openbao_seal_helpers - the package holding the OpenBao seal helpers {{{
sub openbao_seal_helpers {
	my ($self) = @_;
	my $pkg = 'Genesis::Hook::Features::BOSH';
	require( $self->env->kit->path('hooks/features.pm') )
		unless $pkg->can('openbao_seal_state');
	return $pkg;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
