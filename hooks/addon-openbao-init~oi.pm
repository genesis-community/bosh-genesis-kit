package Genesis::Hook::Addon::BOSH::OpenbaoInit v4.1.0;

use v5.20; # Genesis min perl version is 5.20
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info warning run/;
use Digest::SHA ();
use JSON::PP ();
use POSIX qw/strftime/;

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
		"the unseal keys (Shamir seal) or recovery keys (static seal) and the ".
		"initial root token.\n".
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

	# The server's own seal type decides how it initializes: under a static
	# seal, sys/init refuses secret shares (so safe init fails) and takes
	# recovery shares instead.  It must agree with the env's seal mode, or
	# the deployed release is not the one this env expects.
	my $helpers = $self->openbao_seal_helpers;
	my $mode    = $helpers->openbao_seal_state($env)->{mode};
	my $ca_file = $helpers->openbao_ca_file($env, eval { $self->vault });
	my $status  = $helpers->openbao_seal_status($env, ca_file => $ca_file)
		or bail("Cannot read #C{sys/seal-status} from OpenBao at #C{%s}.", $url);
	bail(
		"OpenBao at #C{%s} is already initialized.  Initialization is a one-time ".
		"operation; see #C{genesis %s do openbao-status}.", $url, $env->name
	) if $status->{initialized};
	my $server_type = $status->{type} // 'unknown';
	if ($mode eq 'static' && $server_type ne 'static') {
		bail(
			"This environment uses the #c{static} seal, but OpenBao at #C{%s} reports ".
			"a #c{%s} seal.  The deployed openbao release is probably older than 0.4.0, ".
			"which ignores the seal properties; deploy a release with static seal ".
			"support before initializing.", $url, $server_type
		);
	}
	if ($mode eq 'shamir' && $server_type ne 'shamir') {
		bail(
			"This environment uses the #c{shamir} seal, but OpenBao at #C{%s} reports ".
			"a #c{%s} seal.  Deploy the environment again so the server runs the seal ".
			"its parameters select, then initialize.", $url, $server_type
		);
	}

	# Init replaces the custody paths, and an earlier set of keys there may
	# be the only way to restore an old raft snapshot, so keep a copy first.
	$self->_preserve_custody_paths($helpers);

	return $self->_init_static($url, $helpers, $ca_file) if $mode eq 'static';

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
# _init_static - Initialize a static-sealed server with recovery keys {{{
#
# A static-sealed server unseals itself, so initialization yields recovery
# keys (5 shares, threshold 3) rather than unseal keys.  They authorize a
# seal migration, a root token generation, and a rekey; they never unseal.
# Every secret stays off command lines: the init request and response pass
# through curl's stdin and stdout, the custody copy goes to the deploying
# vault through `safe import` on stdin, and the root token travels as a
# header read from stdin.  The keys are printed once, before any step that
# could fail, so a later failure never loses them.
sub _init_static {
	my ($self, $url, $helpers, $ca_file) = @_;
	my $env = $self->env;
	my @tls = $ca_file ? (ca_file => $ca_file) : (insecure => 1);
	info(
		"#Y{Note:} the OpenBao CA is not in the deploying vault, so TLS ".
		"verification is skipped for initialization."
	) unless $ca_file;

	warning(
		"The recovery keys and initial root token are printed #Y{exactly once} ".
		"below.  Capture rules: run under #C{umask 077}; if logging, use ".
		"#C{script(1)} to a #C{0600} file in your home directory - #R{never} ".
		"a tmux pane or a file under /tmp."
	);

	info("Initializing OpenBao at #C{%s} with a static seal...", $url);
	my ($code, $body) = $helpers->openbao_request($env,
		method => 'PUT', path => 'sys/init', timeout => 60, @tls,
		stdin_body => '{"recovery_shares":5,"recovery_threshold":3}',
	);
	bail(
		"The initialization request to OpenBao at #C{%s} did not complete (%s).  ".
		"Check #C{genesis %s do openbao-status} before retrying: if it reports the ".
		"server as initialized, the recovery keys were not received.",
		$url, $body // 'no response', $env->name
	) unless defined($code);
	bail(
		"OpenBao refused to initialize (HTTP %s): %s",
		$code, $self->_api_errors($helpers, $body)
	) unless $code eq '200';

	my $data  = $helpers->openbao_json($body) || {};
	my $keys  = $data->{recovery_keys_base64} || $data->{recovery_keys} || [];
	my $token = $data->{root_token};
	unless (ref($keys) eq 'ARRAY' && @$keys == 5 && defined($token) && $token ne '') {
		# Never lose an initialization response: print it as received.
		info("#C{IMPORTANT: OpenBao is initialized; save this response securely!}");
		info("#C{".("=" x 60)."}");
		print(($body // '')."\n");
		info("#C{".("=" x 60)."}");
		bail(
			"The initialization response did not hold 5 recovery keys and a root ".
			"token in the expected form, so nothing was backed up.  The raw ".
			"response is printed above; store its keys by hand."
		);
	}

	$self->_backup_static_to_deploying_vault($keys, $token);

	info("");
	info("#C{IMPORTANT: Save these credentials securely!}");
	info("#C{".("=" x 60)."}");
	print join("", map {sprintf("Recovery Key %d: %s\n", $_ + 1, $keys->[$_])} 0 .. $#$keys);
	print "\nInitial Root Token: $token\n";
	info("#C{".("=" x 60)."}");

	$self->_prepare_static_kv($url, $helpers, $token, \@tls);

	info(
		"OpenBao is initialized with a static seal and unseals itself on every ".
		"start.  The 5 recovery keys (any 3 of them) authorize a seal migration, ".
		"a root token generation, or a rekey, and never unseal the server; give ".
		"them to separate custodians.  The seal key itself lives in the deploying ".
		"vault at #C{%sopenbao/seal/static}.", $env->secrets_base
	);
	return $self->done(1);
}

# }}}
# _prepare_static_kv - mount secret/ as KV v2 and write the handshake {{{
# safe init does this on a Shamir server; a static server needs it done
# by hand so the same tooling (and genesis' vault checks) work on both.
sub _prepare_static_kv {
	my ($self, $url, $helpers, $token, $tls) = @_;
	my $env = $self->env;

	my $healthy = 0;
	for (1 .. 30) {
		my ($code) = $helpers->openbao_request($env, path => 'sys/health', timeout => 5, @$tls);
		if (defined($code) && $code eq '200') { $healthy = 1; last }
		sleep 1;
	}
	unless ($healthy) {
		warning(
			"OpenBao did not report itself active within 30 seconds, so #C{secret/} ".
			"was not mounted.  Once #C{genesis %s do openbao-status} shows it ".
			"unsealed and active, mount #C{secret/} as KV v2 and write ".
			"#C{secret/handshake} by hand.", $env->name
		);
		return 0;
	}

	my ($code, $body) = $helpers->openbao_request($env,
		method => 'POST', path => 'sys/mounts/secret', token => $token, @$tls,
		body => '{"type":"kv","options":{"version":"2"}}',
	);
	if (defined($code) && $code =~ /^20[04]$/) {
		info("#G{Mounted} #C{secret/} as a KV v2 secrets engine");
	} elsif (defined($code) && ($body // '') =~ /already in use/) {
		info("#C{secret/} is already mounted");
	} else {
		warning(
			"Could not mount #C{secret/} as KV v2 (%s): %s",
			$code // 'no response', $self->_api_errors($helpers, $body)
		);
		return 0;
	}

	# A new KV v2 mount upgrades its storage for a moment before it takes
	# writes, so the handshake retries briefly.
	for (1 .. 10) {
		($code, $body) = $helpers->openbao_request($env,
			method => 'POST', path => 'secret/data/handshake', token => $token, @$tls,
			body => '{"data":{"knock":"knock"}}',
		);
		if (defined($code) && $code =~ /^20[04]$/) {
			info("#G{Wrote} #C{secret/handshake}");
			return 1;
		}
		sleep 1;
	}
	warning(
		"Could not write #C{secret/handshake} (%s): %s",
		$code // 'no response', $self->_api_errors($helpers, $body)
	);
	return 0;
}

# }}}
# _backup_static_to_deploying_vault - custody copy of the recovery keys {{{
# Same paths as the Shamir custody copy, with kind=recovery recording that
# these keys cannot unseal.  Written with `safe import` on stdin so no key
# or token reaches a command line.  Best-effort, like the Shamir backup:
# the keys are printed right after this either way.
sub _backup_static_to_deploying_vault {
	my ($self, $keys, $token) = @_;
	my $vault = eval { $self->vault };
	if (!$vault) {
		info("#Y{WARNING:} no deploying vault available - recovery keys exist only in the console output below.");
		return 0;
	}
	my $base = ($self->env->secrets_base =~ s{^/+}{}r);
	my %keys = map {("key".($_ + 1) => $keys->[$_])} (0 .. $#$keys);
	my $json = JSON::PP->new->canonical->encode({
		"${base}openbao/seal/keys"  => {%keys, kind => 'recovery'},
		"${base}openbao/root_token" => {token => $token},
	});
	my ($out, $rc, $err) = eval {
		$vault->query({stdin => $json, redact_output => 1, stderr => 0}, 'import')
	};
	if ($@ || $rc) {
		my $why = ($@ || $err || "safe import exited $rc") =~ s/\s+/ /gr;
		info("#Y{WARNING:} failed to back up the recovery keys to the deploying vault: %s", $why);
		return 0;
	}
	info(
		"#G{Backed up} %d recovery key(s) and the root token to the deploying ".
		"vault under #C{%sopenbao/}", scalar(@$keys), $self->env->secrets_base
	);
	return 1;
}

# }}}
# _preserve_custody_paths - move earlier keys aside before init {{{
#
# A server rebuilt with an empty disk initializes fresh, and its keys would
# replace openbao/seal/keys and openbao/root_token in the deploying vault.
# The keys there belong to the earlier server, and they may be the only way
# to restore one of its raft snapshots.  Before init, each existing path is
# copied to <path>-<UTC timestamp> through `safe import` on stdin, read
# back, and compared by SHA-256; init does not start unless every copy
# matches.  Nothing is printed but the path names.
sub _preserve_custody_paths {
	my ($self, $helpers) = @_;
	my $vault = eval { $self->vault } or return 1;
	my $env = $self->env;
	my $stamp = strftime('%Y%m%dT%H%M%SZ', gmtime);
	my $json = JSON::PP->new->canonical;
	for my $relpath ('openbao/seal/keys', 'openbao/root_token') {
		my $data = $helpers->openbao_vault_secret($env, $relpath, $vault) or next;
		my $aside = "$relpath-$stamp";
		my $path = ($env->secrets_base.$aside) =~ s{/{2,}}{/}gr =~ s{^/+}{}r;
		my ($out, $rc, $err) = $vault->query(
			{stdin => $json->encode({$path => $data}), redact_output => 1, stderr => 0}, 'import'
		);
		bail(
			"Could not copy #C{%s} aside to #C{%s} (%s); not initializing, so the ".
			"earlier keys stay where they are.", $relpath, $aside,
			($err // '') =~ s/\s+\z//r || "safe exited $rc"
		) if $rc;
		my $copy = $helpers->openbao_vault_secret($env, $aside, $vault);
		bail(
			"The copy of #C{%s} at #C{%s} does not match the original (compared by ".
			"SHA-256); not initializing.", $relpath, $aside
		) unless $copy && Digest::SHA::sha256_hex($json->encode($copy))
			eq Digest::SHA::sha256_hex($json->encode($data));
		warning(
			"#C{%s} already held keys from an earlier initialization.  They are kept ".
			"at #C{%s} (verified by SHA-256), and initialization replaces the ".
			"original path.", $env->secrets_base.$relpath, $env->secrets_base.$aside
		);
	}
	return 1;
}

# }}}
# _api_errors - the errors list of an OpenBao API error response {{{
sub _api_errors {
	my ($self, $helpers, $body) = @_;
	my $data = $helpers->openbao_json($body);
	return join('; ', @{$data->{errors}})
		if $data && ref($data->{errors}) eq 'ARRAY' && @{$data->{errors}};
	return 'no details returned';
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
