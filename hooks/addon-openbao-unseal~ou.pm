package Genesis::Hook::Addon::BOSH::OpenbaoUnseal v4.1.0;

use v5.20; # Genesis min perl version is 5.20
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info warning run/;
use Genesis::Term qw/in_controlling_terminal/;
use Genesis::UI qw/prompt_for_boolean/;
use JSON::PP ();

# init - Initialize the hook {{{
sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
	return $obj;
}

# }}}
# cmd_details - Documentation that is shown when running with --help {{{
sub cmd_details {
	return
		"Unseal the colocated OpenBao server, making it available for use.\n".
		"Seal keys backed up in the deploying vault are used automatically; ".
		"otherwise you will be prompted for the unseal keys.\n".
		"A server with a static seal unseals itself when its job starts, so ".
		"for one that is sealed this explains the restart that brings it back, ".
		"and offers the stored recovery keys only after you confirm that it ".
		"was sealed by hand.  During a pending seal migration it sends no keys.";
}

# }}}
# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;
	my $env = $self->env;

	bail("#R{[ERROR]} Requires feature openbao")
		unless $env->has_feature('openbao');

	my $ip     = $env->lookup('params.static_ip')
		or bail("params.static_ip is not set for this environment");
	my $port   = $env->lookup('params.openbao_port', 8200);
	my $url    = "https://$ip:$port";
	# Target name must be exactly the env name: genesis (one target per URL)
	# and `ocfp vault migrate` (looks up target "<env>") both key on it.
	my $target = $env->name;

	info("");

	# The seal status decides the path.  Shamir servers keep the original
	# safe-based flow below; static servers and pending migrations never
	# get keys sent blindly.  An unreadable status falls through to the
	# original flow, which reports the problem itself.
	my $helpers = $self->openbao_seal_helpers;
	my $ca_file = $helpers->openbao_ca_file($env, eval { $self->vault });
	my $status  = $helpers->openbao_seal_status($env, ca_file => $ca_file);
	if ($status) {
		my $type = $status->{type} // 'unknown';
		unless ($status->{sealed}) {
			info("#G{OpenBao at %s is already unsealed} (%s seal).", $url, $type);
			return $self->done(1);
		}
		if ($status->{migration}) {
			bail(
				"OpenBao at #C{%s} is sealed with a #c{seal migration pending} (it now ".
				"reports a #c{%s} seal).  A plain unseal is refused in this state, and ".
				"this addon does not send keys during a migration.  Follow the seal ".
				"migration runbook in #C{docs/openbao-operations.md}, which either ".
				"completes the migration with three keys submitted with #c{migrate} set, ".
				"or backs it out.", $url, $type
			);
		}
		return $self->_unseal_static($url, $status, $helpers, $ca_file)
			if $type ne 'shamir';
	}

	{
		local $ENV{SAFE_TARGET} = "";
		my ($out, $rc) = run(
			'safe', 'target', '--no-strongbox', $url, '-k', $target
		);
		bail("Failed to target OpenBao at %s:\n%s", $url, $out) if $rc;
	}

	# Already unsealed?  ("unsealed" contains "sealed", so match the whole
	# word - safe status prints "<url> is unsealed" / "<url> is sealed")
	my ($status_out, $status_rc) = run(
		{stderr => 0}, 'safe', '-T', $target, 'status'
	);
	if ($status_rc == 0 && $status_out =~ /\bunsealed\b/i) {
		info("#G{OpenBao at %s is already unsealed.}", $url);
		return $self->done(1);
	}

	# Try seal keys from the deploying vault (stored by openbao-init).
	my $keys = $self->_stored_seal_keys;
	if ($keys && @$keys) {
		info("Unsealing with %d stored seal key(s) from the deploying vault...", scalar(@$keys));
		my ($out, $rc) = run(
			{stdin => join("\n", @$keys)."\n"},
			'safe', '-T', $target, 'unseal'
		);
		if ($rc == 0) {
			info("#G{OpenBao unsealed successfully.}");
			run({interactive => 1}, 'safe', '-T', $target, 'status');
			return $self->done(1);
		}
		info("#R{Automatic unseal failed:} %s", $out);
		info("Falling back to manual unseal...");
	} else {
		info("No stored seal keys found in the deploying vault - manual unseal.");
	}

	info("Enter the unseal keys when prompted:");
	run({interactive => 1}, 'safe', '-T', $target, 'unseal');
	return $self->done();
}

# }}}
# _unseal_static - handle a sealed server that has a static seal {{{
#
# A static-sealed server unseals itself as its job starts, so being sealed
# means either someone sealed it by hand or it could not use its seal key.
# A job restart is the normal remedy.  The recovery keys can unseal it only
# after a manual seal, so they are offered only once the operator confirms
# that case, and each key travels to sys/unseal on curl's stdin.
sub _unseal_static {
	my ($self, $url, $status, $helpers, $ca_file) = @_;
	my $env = $self->env;

	warning(
		"OpenBao at #C{%s} has a #c{%s} seal and is #R{sealed}.  A static seal ".
		"unseals the server whenever its job starts, so this is a fault, not the ".
		"normal state after a restart.", $url, $status->{type} // 'static'
	);
	info(
		"\nIf the server was #Y{not} sealed by hand, restart the job on the ".
		"director (#C{monit restart openbao}, as root).  It should come back ".
		"unsealed within seconds.  If it stays sealed, its log names the seal ".
		"error; #C{unknown encoding for AES-256 key} means the stored seal key is ".
		"malformed, which #C{genesis check} reports without printing it.\n"
	);

	bail(
		"Not unsealing: confirming a manual seal needs an interactive terminal.  ".
		"Restart the openbao job as described above."
	) unless in_controlling_terminal();

	my $manual = prompt_for_boolean(
		"Was this server sealed by hand (for example with #C{genesis do ".
		"openbao-seal}), and do you want to unseal it with the stored recovery ".
		"keys instead of restarting the job? [y|n] ", 0
	);
	unless ($manual) {
		info("Not unsealing.  Restart the openbao job as described above.");
		return $self->done(0);
	}

	my ($keys, $kind) = $self->_stored_seal_keys;
	bail(
		"No recovery keys were found at #C{%sopenbao/seal/keys} in the deploying ".
		"vault.  Restart the openbao job instead.", $env->secrets_base
	) unless $keys && @$keys;
	info(
		"#Y{Note:} the stored keys are not marked #c{kind: recovery}; after a ".
		"migration to the static seal, the former Shamir shares are the recovery ".
		"keys, so they are used as they are."
	) unless ($kind // '') eq 'recovery';

	my $json = JSON::PP->new->canonical;
	my $need = $status->{t} || 3;
	info("Unsealing with up to %d stored recovery key(s)...", $need);
	for my $i (0 .. $#$keys) {
		my ($code, $body) = $helpers->openbao_request($env,
			method => 'PUT', path => 'sys/unseal',
			stdin_body => $json->encode({key => $keys->[$i]}),
			($ca_file ? (ca_file => $ca_file) : (insecure => 1)),
		);
		my $data = $helpers->openbao_json($body);
		unless (defined($code) && $code eq '200' && $data) {
			my $why = ($data && ref($data->{errors}) eq 'ARRAY')
				? join('; ', @{$data->{errors}})
				: ($body // 'no response');
			bail("OpenBao refused recovery key %d (HTTP %s): %s", $i + 1, $code // '-', $why);
		}
		unless ($data->{sealed}) {
			info("#G{OpenBao unsealed successfully} with %d recovery key(s).", $i + 1);
			return $self->done(1);
		}
		info("  key %d accepted, progress %s of %s", $i + 1, $data->{progress} // '?', $data->{t} // $need);
	}
	bail(
		"OpenBao is still sealed after all %d stored recovery keys.  Restart the ".
		"openbao job instead, and check its log for seal errors.", scalar(@$keys)
	);
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
# _stored_seal_keys - fetch the custody copy from the deploying vault {{{
sub _stored_seal_keys {
	my ($self) = @_;
	my $vault = eval { $self->vault } or return undef;
	my $path  = $self->env->secrets_base . 'openbao/seal/keys';
	my $data  = eval { $vault->get($path) } or return undef;
	return undef unless ref($data) eq 'HASH';
	my @keys =
		map  { $data->{$_} }
		sort { ($a =~ /(\d+)/)[0] <=> ($b =~ /(\d+)/)[0] }
		grep { /^key\d+$/ } keys %$data;
	# In list context, also return the kind (recovery for a static seal).
	return wantarray ? ((@keys ? \@keys : undef), $data->{kind}) : (@keys ? \@keys : undef);
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
