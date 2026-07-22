package Genesis::Hook::Addon::BOSH::OpenbaoInit v4.1.0;

use v5.20; # Genesis min perl version is 5.20
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info warning run/;

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
		"Initialize the colocated OpenBao server on the director, generating ".
		"the unseal keys and initial root token.\n".
		"This should only be done once per deployment.  The keys and root ".
		"token are printed once for operator capture and backed up to the ".
		"deploying vault; they are never written to the director VM.";
}

# }}}
# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;
	my $env = $self->env;

	bail("#R{[ERROR]} Requires feature openbao")
		unless $env->has_feature('openbao');

	my $url    = $self->_openbao_url;
	# Target name must be exactly the env name: genesis (one target per URL)
	# and `ocfp vault migrate` (looks up target "<env>") both key on it.
	my $target = $env->name;

	info("");
	$self->_check_reachable($url);

	warning(
		"The unseal keys and initial root token are printed #Y{exactly once} ".
		"below.  Capture rules: run under #C{umask 077}; if logging, use ".
		"#C{script(1)} to a #C{0600} file in your home directory - #R{never} ".
		"a tmux pane or a file under /tmp."
	);

	$self->_target_openbao($url, $target);

	info("Initializing OpenBao at #C{%s}...", $url);
	my ($init_out, $init_rc) = run('safe', '-T', $target, 'init');
	if ($init_rc != 0) {
		bail("Failed to initialize OpenBao:\n%s", $init_out);
	}

	# safe init unseals, authenticates with the root token, and stores the
	# seal keys in-cluster at secret/vault/seal/keys itself; only the
	# deploying-vault custody copy is ours to make.
	$self->_verify_in_cluster_keys($target);
	my ($seal_keys, $root_token) = $self->_parse_seal_keys($init_out);
	if (!$seal_keys) {
		info("#Y{Note:} could not parse unseal keys from the init output.");
	} else {
		$self->_backup_to_deploying_vault($seal_keys, $root_token);
	}

	info("");
	info("#C{IMPORTANT: Save these credentials securely!}");
	info("#C{".("=" x 60)."}");
	print $init_out."\n";
	info("#C{".("=" x 60)."}");
	info(
		"OpenBao is initialized.  Distribute the unseal keys to separate ".
		"custodians; any 3 of the 5 are needed to unseal after a restart ".
		"(#C{genesis %s do openbao-unseal}).", $env->name
	);

	return $self->done(1);
}

# }}}
# _openbao_url - Compose the OpenBao URL from kit params {{{
sub _openbao_url {
	my ($self) = @_;
	my $ip = $self->env->lookup('params.static_ip')
		or bail("params.static_ip is not set for this environment");
	my $port = $self->env->lookup('params.openbao_port', 8200);
	return "https://$ip:$port";
}

# }}}
# _check_reachable - Bail early if the OpenBao listener is not up {{{
sub _check_reachable {
	my ($self, $url) = @_;
	my $timeout = $ENV{TIMEOUT} // 3;
	my (undef, $rc) = run(
		{stdout => 0, stderr => 0},
		'curl', '-Lsk', "-m$timeout", "$url/v1/sys/health"
	);
	bail(
		"Cannot reach OpenBao at #C{%s} - is the deployment up and the ".
		"#c{openbao} job running?", $url
	) if $rc != 0;
}

# }}}
# _target_openbao - Create/refresh the safe target for the colocated OpenBao {{{
sub _target_openbao {
	my ($self, $url, $target) = @_;
	local $ENV{SAFE_TARGET} = "";
	my ($out, $rc) = run(
		'safe', 'target', '--no-strongbox', $url, '-k', $target
	);
	bail("Failed to target OpenBao at %s:\n%s", $url, $out) if $rc;
}

# }}}
# _parse_seal_keys - Parse unseal keys and root token from init output {{{
sub _parse_seal_keys {
	my ($self, $init_out) = @_;
	my (@keys, $root_token);

	for my $line (split /\n/, $init_out // '') {
		if ($line =~ /^Unseal Key (?:#?\d+)?:?\s*(.+)$/i) {
			my $key = $1 =~ s/^\s+|\s+$//gr;
			push @keys, $key if $key =~ m{^[A-Za-z0-9+/=]+$};
		} elsif ($line =~ /^(?:Initial )?Root Token:\s*(.+)$/i) {
			$root_token = $1 =~ s/^\s+|\s+$//gr;
		}
	}
	return (undef, undef) unless @keys && $root_token;
	return (\@keys, $root_token);
}

# }}}
# _verify_in_cluster_keys - confirm safe init persisted the seal keys {{{
# Path "secret/vault/seal/keys" is the safe CLI convention for seal key
# storage - safe automatic unseal depends on it.  Do not rename.  This is
# a read-only check; key material never appears on a command line.
sub _verify_in_cluster_keys {
	my ($self, $target) = @_;
	my (undef, $rc) = run(
		{stdout => 0},
		'safe', '-T', $target, 'exists', 'secret/vault/seal/keys'
	);
	if ($rc == 0) {
		info("#G{Verified} in-cluster seal key copy at #C{secret/vault/seal/keys}");
	} else {
		info(
			"#Y{WARNING:} no in-cluster seal key copy found at ".
			"#C{secret/vault/seal/keys} - was safe run with --no-persist?"
		);
	}
	return $rc == 0;
}

# }}}
# _backup_to_deploying_vault - custody copy in the deploying vault {{{
# The in-cluster copy is circular custody: once OpenBao seals, the keys
# needed to unseal it are unreachable.  Back them up to the vault Genesis
# deploys this environment from, under this env's own secrets base.
# Best-effort: never fails init - the keys were already printed above.
sub _backup_to_deploying_vault {
	my ($self, $seal_keys, $root_token) = @_;

	my $vault = eval { $self->vault };
	if (!$vault) {
		info("#Y{WARNING:} no deploying vault available - seal keys exist only in the console output above.");
		return 0;
	}

	my $base = $self->env->secrets_base;
	my %keys = map {("key".($_ + 1) => $seal_keys->[$_])} (0 .. $#$seal_keys);
	eval {
		$vault->set_path($base.'openbao/seal/keys', \%keys);
		$vault->set($base.'openbao/root_token', 'token', $root_token);
	};
	if (my $err = $@) {
		$err =~ s/\n/ /g;
		info("#Y{WARNING:} failed to back up seal keys to the deploying vault: %s", $err);
		return 0;
	}
	info(
		"#G{Backed up} %d seal key(s) and the root token to the deploying ".
		"vault under #C{%sopenbao/}", scalar(@$seal_keys), $base
	);
	return 1;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
