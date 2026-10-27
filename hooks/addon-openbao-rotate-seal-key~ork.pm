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
use POSIX qw/strftime/;
use Service::Vault;

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
		"  escrow --escrow-target <safe target>\n".
		"      Copy the current key (and the previous key, during a rotation) to ".
		"the escrow vault, check each copy by SHA-256, and record the escrow at ".
		"openbao/seal/escrow.  A deploy that starts the static seal needs this ".
		"record for the current key.  Outside a rotation, the target may be the ".
		"vault this environment deploys from, such as a new director's inception ".
		"vault, as long as it is not this environment's own OpenBao; nothing is ".
		"copied then, and the record names that vault.\n".
		"  start [--escrow-target <safe target> | --skip-escrow]\n".
		"      Keep the current key and its id at openbao/seal/static-previous, ".
		"generate a new key at openbao/seal/static, and copy both to the escrow ".
		"vault, checked by hash.  Then deploy, check the openbao log, and restart ".
		"the job once.\n".
		"  finish [--yes]\n".
		"      Once a deploy has rendered both keys, the server is unsealed, and ".
		"the new key is escrowed, remove openbao/seal/static-previous; deploy ".
		"and restart again afterwards.  --yes only skips the prompt.\n".
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

	# Step 4: escrow the new key, and record the escrow.
	if ($escrow) {
		$self->_escrow_path($escrow, 'openbao/seal/static');
		$self->_write_escrow_record($escrow, $new, $current);
	}
	warning(
		"The seal keys were #R{not escrowed} (--skip-escrow).  Run the #c{escrow} ".
		"action before deploying; #c{finish} refuses until the new key is escrowed.  ".
		"The paths are #C{%s} and #C{%s}.",
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

	bail("#c{finish} does not take #c{--skip-escrow}; the new key must be escrowed first.")
		if $self->{options}{'skip-escrow'};

	my $previous = $helpers->openbao_vault_secret($env, 'openbao/seal/static-previous');
	bail("No rotation is under way: #C{openbao/seal/static-previous} does not exist.")
		unless $previous;
	my $current = $self->_read_key('openbao/seal/static', 'current');
	bail(
		"The previous key is still the same as the current key, so #c{start} did ".
		"not finish.  Run #C{genesis %s do openbao-rotate-seal-key start} again.",
		$env->name
	) if ($previous->{key} // '') eq $current;
	my $current_id = $helpers->openbao_static_key_id($current);

	# The new key must exist outside the provider before the old one goes.
	my $escrow = $helpers->openbao_vault_secret($env, 'openbao/seal/escrow');
	bail(
		"The new key (id #C{%s}) has no verified escrow.  Run #C{genesis %s do ".
		"openbao-rotate-seal-key escrow --escrow-target <vault>} first.",
		$current_id, $env->name
	) unless $escrow && ($escrow->{id} // '') eq $current_id;

	# An escrow held in the deploying vault would lose its only copy of the
	# previous key below; the escrow action refuses to record one during a
	# rotation, and this catches a record written some other way.
	my $deploying = eval { $self->vault->url } // '';
	if ($deploying ne '') {
		my $same = $self->_normalized_url($escrow->{url} // '') eq $self->_normalized_url($deploying);
		$same ||= defined($escrow->{cluster_id})
			&& ($self->_vault_cluster_id($deploying) // '') eq $escrow->{cluster_id};
		bail(
			"The escrow record names #C{%s}, which is the vault this environment ".
			"deploys from, so removing the previous key here would remove its only ".
			"copy.  Escrow both keys to a different vault first with #C{genesis %s do ".
			"openbao-rotate-seal-key escrow --escrow-target <vault>}.",
			$escrow->{target} // $escrow->{url} // 'unknown', $env->name
		) if $same;
	}

	# A deploy must have rendered both keys, and the server must have come
	# up unsealed on the new one since.  The previous-key overlay records the
	# previous id in the exodus data, and the post-deploy hook records the
	# current id only after it sees the static server unsealed.
	my $exodus = eval { $env->exodus_lookup('.', undef) };
	$exodus = {} unless ref($exodus) eq 'HASH';
	bail(
		"No deploy has rendered both keys yet: the exodus data does not record ".
		"previous key id #C{%s}.  Deploy (#C{genesis deploy %s}), check the openbao ".
		"log, and restart the job once before finishing.",
		$previous->{id} // 'unknown', $env->name
	) unless ($exodus->{openbao_static_previous_key_id} // '') eq ($previous->{id} // "\0");
	bail(
		"The exodus data does not record the server running on the new key (id ".
		"#C{%s}); it records #C{%s}.  Deploy again so the post-deploy check sees ".
		"the server unsealed, then finish.",
		$current_id, $exodus->{openbao_static_key_id} // 'nothing'
	) unless ($exodus->{openbao_static_key_id} // '') eq $current_id;

	$self->_require_healthy_static_server;

	info(
		"Removing the previous key is safe only when all of these are true:\n".
		"[[  - >>the environment was deployed with both keys (confirmed),\n".
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
		"from the escrow vault (#C{safe -T %s rm %s}).",
		$cmd, $escrow->{target} // '<escrow>', $env->secrets_base.'openbao/seal/static-previous'
	);
	return $self->done(1);
}

# }}}
# _escrow_all - copy both keys to the escrow vault again {{{
#
# Outside a rotation, the target may be the deploying vault itself, as long
# as that vault is not this environment's own OpenBao.  A new director that
# deploys from the bastion's inception vault is the usual case: that vault
# already holds the key outside the director, so nothing is copied, and the
# record names the deploying vault as the escrow.
sub _escrow_all {
	my ($self) = @_;
	bail("The #c{escrow} action needs #c{--escrow-target}.")
		if $self->{options}{'skip-escrow'} || !$self->{options}{'escrow-target'};
	my $env = $self->env;
	my $helpers = $self->openbao_seal_helpers;
	my $previous = $helpers->openbao_vault_secret($env, 'openbao/seal/static-previous');
	my $escrow = $self->_escrow_choice(in_place => !$previous);
	my $current = $self->_read_key('openbao/seal/static', 'current');
	$self->_escrow_path($escrow, 'openbao/seal/static');
	$self->_escrow_path($escrow, 'openbao/seal/static-previous') if $previous;
	$self->_write_escrow_record($escrow, $current, $previous ? $previous->{key} : undef);
	info(
		"The key's custody is #C{%s} (#C{%s}), the external vault this environment ".
		"deploys from.  It is not this environment's OpenBao, because %s, so it ".
		"already holds the key outside the director.  If the secrets move to the ".
		"director's OpenBao later, keep this vault's copy of #C{%s}, because it ".
		"becomes the escrow copy, and run this action again with ".
		"#c{--escrow-target %s} afterwards to copy the key and check it by SHA-256.  ".
		"Anything that decommissions this vault, such as #c{ocfp vault migrate --force}, ".
		"destroys the escrow, so escrow the key to a vault that outlasts it first.",
		$escrow->{name}, $escrow->{url}, $escrow->{why},
		$env->secrets_base.'openbao/seal/static', $escrow->{name}
	) if $escrow->{in_place};
	return $self->done(1);
}

# }}}
# _write_escrow_record - note a verified escrow in the deploying vault {{{
#
# Written only after every copy matched by SHA-256.  It holds no secret:
# the escrow vault's target name, URL, and cluster id, and the ids of the
# keys it holds.  The check hook requires it, for the current key, before a
# deploy that starts the static seal, and finish requires it for the new key.
sub _write_escrow_record {
	my ($self, $escrow, $current, $previous) = @_;
	my $helpers = $self->openbao_seal_helpers;
	my $record = {
		target      => $escrow->{name},
		url         => $escrow->{url},
		id          => $helpers->openbao_static_key_id($current),
		escrowed_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
	};
	$record->{cluster_id}  = $escrow->{cluster_id} if defined $escrow->{cluster_id};
	$record->{previous_id} = $helpers->openbao_static_key_id($previous) if defined $previous;
	$self->_write('openbao/seal/escrow', $record);
	my $check = $helpers->openbao_vault_secret($self->env, 'openbao/seal/escrow');
	bail("Could not read back the escrow record at #C{openbao/seal/escrow}.")
		unless $check && ($check->{id} // '') eq $record->{id};
	info(
		"#G{Recorded} the escrow of key id #C{%s} in #C{%s} at #C{openbao/seal/escrow}.",
		$record->{id}, $escrow->{name}
	);
	return 1;
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
#
# The escrow must hold the key outside the OpenBao it unseals.  A target
# that is the deploying vault is refused when the deploying vault is this
# environment's own OpenBao, and when the kit cannot prove that it is not.
# Otherwise, and only when the caller passes in_place (the escrow action
# outside a rotation), it is accepted as is: the returned target carries
# in_place, and why the deploying vault is not this environment's OpenBao.
# A rotation always needs a copy in a different vault, because finish
# removes the previous key from the deploying vault while the escrow copy
# has to outlive it.  A different vault is refused when it is this
# environment's own OpenBao.
sub _escrow_choice {
	my ($self, %o) = @_;
	my $target = $self->{options}{'escrow-target'};
	my $skip   = $self->{options}{'skip-escrow'};
	bail("Pass either #c{--escrow-target} or #c{--skip-escrow}, not both.") if $target && $skip;
	return undef if $skip;
	bail(
		"Name the escrow vault with #c{--escrow-target <safe target>}, or pass ".
		"#c{--skip-escrow} to rotate without an escrow copy."
	) unless $target;

	# Compare vaults, not alias names: two targets can point at one vault.
	my @found = $self->_vault_targets_named($target);
	bail("No #c{safe} target named #C{%s}; check #c{safe targets}.", $target) unless @found;
	bail("More than one #c{safe} target is named #C{%s}.", $target) if @found > 1;
	my $url = $found[0]{url};
	bail("The #c{safe} target #C{%s} has no URL.", $target) unless $url;

	my $own_url = eval { $self->vault->url } // '';
	my $same_url = $own_url ne '' && $self->_normalized_url($url) eq $self->_normalized_url($own_url);
	my $escrow_id = $self->_vault_cluster_id($url);
	my $own_id = $own_url eq '' ? undef
		: $same_url ? $escrow_id
		: $self->_vault_cluster_id($own_url);
	my $same_id = !$same_url && defined($escrow_id) && defined($own_id) && $escrow_id eq $own_id;

	if ($same_url || $same_id) {
		my ($is, $why) = $self->_own_openbao($own_url, $own_id);
		if ($is eq 'own') {
			bail(
				"The escrow target #C{%s} points at #C{%s}, which is the vault this ".
				"environment deploys from.  Escrow needs a different vault.", $target, $url
			) if $same_url;
			bail(
				"The escrow target #C{%s} reports the same cluster id as the vault this ".
				"environment deploys from, so it is the same vault under another address.  ".
				"Escrow needs a different vault.", $target
			);
		}
		bail(
			"The escrow target #C{%s} is the vault this environment deploys from, and ".
			"the kit cannot prove that it is not this environment's own OpenBao, because ".
			"%s.  Escrow needs a vault outside that OpenBao, so name a different vault, ".
			"or run this again from a host that reaches the deploying vault's ".
			"#C{sys/leader} and the director's OpenBao.", $target, $why
		) unless $is eq 'other';
		bail(
			"The escrow target #C{%s} is the vault this environment deploys from.  It ".
			"is not this environment's OpenBao, so the #c{escrow} action accepts it ".
			"outside a rotation, but a rotation needs a copy in a different vault, ".
			"because #c{finish} removes the previous key from the deploying vault and ".
			"the escrow copy has to outlive it.  Name a different vault.", $target
		) unless $o{in_place};
		return {name => $target, url => $url, cluster_id => $escrow_id, in_place => 1, why => $why};
	}

	my ($is, $why) = $self->_own_openbao($url, $escrow_id);
	bail(
		"The escrow target #C{%s} is this environment's own OpenBao, because %s.  The ".
		"key would have no copy outside the server it unseals.  Escrow needs a ".
		"different vault.", $target, $why
	) if $is eq 'own';

	return {name => $target, url => $url, cluster_id => $escrow_id};
}

# }}}
# _own_openbao - whether a vault is this environment's own OpenBao {{{
#
# Returns ('own', why), ('other', why), or ('unknown', why), where why is a
# clause that completes "because ...".  The kit renders one OpenBao node on
# the director, at https://<params.static_ip>:<params.openbao_port>, and
# its api_addr is that same address.  A vault is this environment's own
# OpenBao when any of these is true:
#   - its URL's host is the director's static IP, whatever the port;
#   - it reports the cluster id that the OpenBao at the director's address
#     reports in sys/health; or
#   - sys/leader names the director's static IP as its leader.
# It is another vault only on positive proof: the two cluster ids differ,
# or it answered sys/leader with a leader other than the director.  A new
# director's OpenBao does not answer at all, so the sys/leader answer is
# what proves the bastion's vault is not it.  Without params.static_ip, or
# without either proof, the answer is unknown, and callers that need
# "other" refuse.
sub _own_openbao {
	my ($self, $url, $cluster_id) = @_;
	my $helpers = $self->openbao_seal_helpers;
	my $ip = $self->env->lookup('params.static_ip', undef);
	return ('unknown', "#c{params.static_ip} is not set, so the kit cannot tell where this environment's OpenBao listens")
		unless defined($ip) && !ref($ip) && $ip ne '';
	$ip = lc($ip) =~ s{\A\s*\[?|\]?\s*\z}{}gr;
	my $own_url = $helpers->openbao_url($self->env);

	return ('own', "its address is the director's static IP, #C{$ip}")
		if ($helpers->openbao_url_host($url) // '') eq $ip;

	my $own_id = $self->_vault_cluster_id($own_url);
	return ('own', "it reports the cluster id of this environment's OpenBao at #C{$own_url}")
		if defined($own_id) && defined($cluster_id) && $own_id eq $cluster_id;

	my $leader = $self->_vault_leader($url);
	if ($leader) {
		for my $addr (grep {defined($_) && !ref($_)} @{$leader}{qw/leader_address leader_cluster_address/}) {
			return ('own', "it names the director, #C{$ip}, as its leader")
				if ($helpers->openbao_url_host($addr) // '') eq $ip;
		}
	}
	return ('other', "its cluster id differs from the one this environment's OpenBao at #C{$own_url} reports")
		if defined($own_id) && defined($cluster_id);
	return ('other', sprintf(
		"it names %s as its leader in #C{sys/leader}, not the director (#C{%s})",
		($leader->{leader_address} // '') ne '' ? "#C{$leader->{leader_address}}" : 'no address',
		$ip
	)) if $leader;
	return ('unknown', sprintf(
		"it did not answer #C{sys/leader}, and %s",
		defined($own_id)
			? "it reported no cluster id to compare with that of this environment's OpenBao at #C{$own_url}"
			: "this environment's OpenBao at #C{$own_url} reported no cluster id"
	));
}

# _vault_targets_named - safe targets with this name, as {name, url} {{{
sub _vault_targets_named {
	my ($self, $name) = @_;
	return map { {name => $_->name, url => $_->url} } Service::Vault->find(name => $name);
}

# }}}
# _vault_cluster_id - the cluster id a vault reports in sys/health, or undef {{{
# sys/health is unauthenticated and carries no secrets, so it skips TLS
# verification; the id only tells two addresses for one vault apart.
sub _vault_cluster_id {
	my ($self, $url) = @_;
	my ($out, $rc) = run(
		{stderr => 0},
		'curl', '-sk', '--connect-timeout', '3', '-m', '5',
		$self->_normalized_url($url).'/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=200&uninitcode=200&drsecondarycode=200'
	);
	return undef if $rc;
	my $data = eval { JSON::PP->new->decode($out) };
	return (ref($data) eq 'HASH' && $data->{cluster_id}) ? $data->{cluster_id} : undef;
}

# }}}
# _vault_leader - the sys/leader answer of a vault, or undef {{{
# sys/leader is unauthenticated and carries no secrets, so, like the
# cluster id lookup, it skips TLS verification.  Only an answer that says
# whether HA is enabled counts; a sealed vault answers with an error.
sub _vault_leader {
	my ($self, $url) = @_;
	my ($out, $rc) = run(
		{stderr => 0},
		'curl', '-sk', '--connect-timeout', '3', '-m', '5',
		$self->_normalized_url($url).'/v1/sys/leader'
	);
	return undef if $rc;
	my $data = eval { JSON::PP->new->decode($out) };
	return (ref($data) eq 'HASH' && exists($data->{ha_enabled})) ? $data : undef;
}

# }}}
# _normalized_url - scheme://host:port[/path] in lowercase, default port filled in {{{
# See openbao_url_parts for what counts as one address.  Anything that is
# not an http or https URL is only lowercased and trimmed.
sub _normalized_url {
	my ($self, $url) = @_;
	my ($scheme, $host, $port, $path) = $self->openbao_seal_helpers->openbao_url_parts($url);
	return lc($url // '') =~ s{\A\s+|\s+\z}{}gr =~ s{/+\z}{}r unless defined $scheme;
	$host = "[$host]" if $host =~ /:/;
	return "$scheme://$host:$port$path";
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
#
# An escrow held in place (see _escrow_choice) is the deploying vault
# itself, so there is nothing to copy; the secret only has to be there.
sub _escrow_path {
	my ($self, $escrow, $relpath) = @_;
	my $target = $escrow->{name};
	if ($escrow->{in_place}) {
		my $data = $self->openbao_seal_helpers->openbao_vault_secret($self->env, $relpath);
		bail("#C{%s} is not in the deploying vault #C{%s}, so it cannot be held there as the escrow.", $relpath, $target)
			unless $data && defined($data->{key});
		info("#G{Kept} #C{%s} in #C{%s}, the vault this environment deploys from; nothing was copied.", $relpath, $target);
		return 1;
	}
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
