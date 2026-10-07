package Genesis::Hook::Features::BOSH v4.1.0;

use v5.20;
use warnings;

BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use parent qw(Genesis::Hook::Features);

use Genesis qw/bail run workdir mkfile_or_fail/;
use JSON::PP ();

# init - Initialize the hook and check minimum Genesis version {{{
sub init {
	my ($class, %opts) = @_;
	my $obj = $class->SUPER::init(%opts);
	$obj->check_minimum_genesis_version('3.1.0-rc.14');
	return $obj;
}

# }}}

# perform - Process and validate features for the BOSH kit {{{
sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	for my $feature ($self->features) {
		bail(
			"Cannot specify a virtual feature: please specify $feature without the ".
			"preceeding '+' to position it in the feature list."
		) if ($feature =~ /^\+(.*)$/);
		$feature = 'external-db-postgres' if $feature eq 'external-db'; # feature renamed
		$self->add_feature($feature);
	}

	# Inject +<iaas> so provided:/credentials:+<iaas> in kit.yml are
	# reachable via FromKit.  OCFP sources IaaS creds elsewhere.
	$self->add_feature('+'.$self->iaas)
		if $self->iaas && !$self->has_feature('ocfp');

	# Handle the proto feature - save and delete it if it exists,
	# then add it as a virtual feature if needed
	my $had_proto = delete($self->{has_feature}{proto});
	if ($self->env->use_create_env || $had_proto) {
		unshift @{$self->{all_features}}, '+proto';
		$self->{has_feature}{'+proto'} = 1;
	}

	if ($self->iaas eq 'aws') {
		$self->add_feature('+aws-secret-access-keys',
			!$self->has_feature('iam-instance-profile') && !$self->has_feature('ocfp')
		);
		if ($self->has_feature('s3-blobstore') && !$self->has_feature('ocfp')) {
			$self->add_feature('+s3-blobstore-secret-access-keys',!$self->has_feature('s3-blobstore-iam-instance-profile'));
		}
	} else {
		$self->add_feature('+s3-blobstore-secret-access-keys',$self->has_feature('s3-blobstore'));
	}

	if ($self->has_feature('ocfp')) {
		$self->add_feature('+internal-blobstore',$self->has_feature('internal-blobstore'));
		bail(
			"Invalid feature 'external-db-no-tls' while specifying 'internal-db' feature."
		) if $self->has_feature('internal-db') && $self->has_feature('external-db-no-tls');
		$self->add_feature('+ocfp-ext-db') unless ($self->delete_feature('internal-db'));
	} else {
		bail(
			"Invalid feature 'internal-db' without 'ocfp' feature."
		) if $self->has_feature('internal-db');
		$self->add_feature('+internal-blobstore',!$self->has_feature('s3-blobstore') && !$self->has_feature('minio-blobstore'));
		$self->add_feature('+external-db',$self->has_feature('external-db-postgres') || $self->has_feature('external-db-mysql'));
	}

	# OCFP management gatekeeping
	if ($self->has_feature('ocfp')) {
		if( $self->env->name =~ /-mgmt(-|$)/) {
			bail(
				"Cannot deploy an OCFP management environment without ".
				"#y{genesis.use_create_env} enabled in the environment file."
			) unless $self->env->use_create_env;
			$self->add_feature('+proto');
		}
		$self->add_feature('+doomsday-credentials');
		$self->add_feature('+blacksmith-credentials');
	} else {
		$self->add_feature('+doomsday-credentials') if $self->has_feature('doomsday-integration');
		$self->add_feature('+blacksmith-credentials') if $self->has_feature('blacksmith-integration');
	}

	# OpenBao seal mode: +openbao-static-seal scopes the static seal key in
	# kit.yml and selects the static overlays in the blueprint.  It only
	# ever exists alongside the openbao feature, so envs without OpenBao
	# get no seal overlay and no seal credential.  This hook runs for every
	# command (including the emergency openbao-unseal addon), so the
	# decision must never die: anything it cannot determine resolves to
	# shamir, and the check hook decides whether the deploy may proceed.
	if ($self->has_feature('openbao')) {
		my $state = $self->openbao_seal_state($self->env);
		$self->add_feature('+openbao-static-seal') if $state->{mode} eq 'static';
	}

	return $self->done([
		$self->build_features_list(
			# `s3-blobstore` was truncated from
			# `s3-blobstore-secret-access-keys` in the port from the
			# bash hook; that silently stripped `s3-blobstore` from
			# the output list and left blueprint's dispatch dead.
			virtual_features => [
				"aws-secret-access-keys",
				"s3-blobstore-secret-access-keys",
				"internal-blobstore",
				"external-db",
			],
		)
	]);
}

# }}}

# OpenBao seal helpers {{{
#
# Kit hooks are separate modules with no shared library.  Genesis runs this
# features hook before any other hook of an env, so the check, post-deploy,
# and openbao addon hooks call these as class methods on
# Genesis::Hook::Features::BOSH, loading this file first if it is not
# already loaded (see openbao_helpers below).

# openbao_seal_state - the env's chosen OpenBao seal mode, never dies {{{
#
# Returns a hashref:
#   mode     - 'static' or 'shamir'; what the kit renders
#   param    - the params.openbao_seal value, or undef when it is not set
#   valid    - false when the param is set to something other than
#              static or shamir (mode is then shamir, and the check hook
#              fails the deploy)
#   existing - only when the param is missing: true when the env has
#              deployed OpenBao before (exodus has_openbao, or the endpoint
#              answers as initialized), or when that cannot be determined
#   source   - 'param', 'exodus', 'new-default', or 'existing-default'
#
# A missing param defaults to static only for an env that has never deployed
# OpenBao.  When the exodus data records the seal mode this kit last
# rendered (exodus openbao_seal), that mode is kept, so an env that took
# the static default stays static.  Any other existing env without the
# param renders shamir, which is what it runs today, and the check hook
# stops its deploy until the operator chooses a mode explicitly.  The result
# is memoized on the env object.
sub openbao_seal_state {
	my ($class, $env) = @_;
	return $env->{__bosh_openbao_seal_state}
		if ref($env) && ref($env->{__bosh_openbao_seal_state}) eq 'HASH';

	my $state = eval { $class->_openbao_seal_state($env) };
	$state = {
		param    => undef,
		valid    => 1,
		mode     => 'shamir',
		existing => 1,
		source   => 'existing-default',
	} unless ref($state) eq 'HASH';

	$env->{__bosh_openbao_seal_state} = $state if ref($env);
	return $state;
}

sub _openbao_seal_state {
	my ($class, $env) = @_;
	my $param = $env->lookup('params.openbao_seal', undef);
	if (defined($param) && !ref($param) && $param ne '') {
		my $valid = ($param eq 'static' || $param eq 'shamir') ? 1 : 0;
		return {
			param  => $param,
			valid  => $valid,
			mode   => $valid ? $param : 'shamir',
			source => 'param',
		};
	}
	return {
		param  => undef,
		valid  => 0,
		mode   => 'shamir',
		source => 'param',
	} if defined($param) && ref($param);

	# The seal overlays record the mode they rendered in the exodus data, so
	# an env this kit deployed without the param keeps the seal it runs.
	my $recorded = eval { $env->exodus_lookup('openbao_seal', '') } // '';
	return {
		param    => undef,
		valid    => 1,
		existing => 1,
		mode     => $recorded,
		source   => 'exodus',
	} if $recorded eq 'static' || $recorded eq 'shamir';

	my $existing = $class->openbao_previously_deployed($env);
	return {
		param    => undef,
		valid    => 1,
		existing => $existing,
		mode     => $existing ? 'shamir' : 'static',
		source   => $existing ? 'existing-default' : 'new-default',
	};
}

# }}}
# openbao_previously_deployed - has this env ever run OpenBao? {{{
#
# True when the exodus data records has_openbao, or when the endpoint
# answers sys/init as initialized.  When the exodus data cannot be read (a
# sealed or unreachable provider, for example), the answer is true: treating
# an unknown env as existing can only stop a deploy, never migrate a seal.
# The endpoint probe is read-only and carries no secrets, so it skips TLS
# verification rather than reach into the vault for the CA.
sub openbao_previously_deployed {
	my ($class, $env) = @_;
	my $recorded = eval { $env->exodus_lookup('has_openbao', '') };
	return 1 if $@;
	return 1 if $recorded;

	my ($code, $body) = $class->openbao_request($env,
		path => 'sys/init', timeout => 4, insecure => 1,
	);
	return 0 unless defined($code) && $code eq '200';
	my $data = $class->openbao_json($body);
	return ($data && $data->{initialized}) ? 1 : 0;
}

# }}}
# openbao_url - https://<static_ip>:<openbao_port> {{{
sub openbao_url {
	my ($class, $env) = @_;
	my $ip = $env->lookup('params.static_ip', undef);
	return undef unless defined($ip) && $ip ne '';
	my $port = $env->lookup('params.openbao_port', 8200);
	return "https://$ip:$port";
}

# }}}
# openbao_ca_file - write the OpenBao CA from the deploying vault to a file {{{
# Returns the path of a 0600 file in the Genesis workdir, or undef when the
# CA cannot be read (callers then fall back to skipping verification).
sub openbao_ca_file {
	my ($class, $env, $vault) = @_;
	my $ca = eval {
		$vault //= $env->vault;
		$vault->get($env->secrets_base.'openbao/ca', 'certificate');
	};
	return undef unless defined($ca) && $ca =~ /BEGIN CERTIFICATE/;
	my $file = workdir().'/openbao-ca.pem';
	eval { mkfile_or_fail($file, 0600, $ca."\n"); 1 } or return undef;
	return $file;
}

# }}}
# openbao_request - one HTTP call to the colocated OpenBao API {{{
#
# Options:
#   method     - HTTP method (default GET)
#   path       - API path under /v1/, such as 'sys/seal-status'
#   stdin_body - a request body that carries secrets; sent on stdin
#   body       - a request body with no secrets; sent as an argument
#   token      - an OpenBao token; sent as a header on stdin
#   ca_file    - verify the server against this CA (default: -k)
#   insecure   - skip verification explicitly
#   timeout    - total seconds (default 10)
#
# Secrets never reach the command line: a token travels as a header read
# from stdin, and a secret body travels on stdin.  curl reads only one of
# them from stdin, so passing both is a programming error.
#
# Returns (http_code, body), or (undef, error) when curl itself fails.
sub openbao_request {
	my ($class, $env, %o) = @_;
	die "openbao_request: pass either token or stdin_body, not both\n"
		if defined($o{token}) && defined($o{stdin_body});

	my $url = $class->openbao_url($env)
		or return (undef, 'params.static_ip is not set');
	my $method  = $o{method}  // 'GET';
	my $timeout = $o{timeout} // 10;

	my @cmd = (
		'curl', '-sS', '--connect-timeout', '3', '-m', $timeout,
		'-X', $method, '-w', "\n%{http_code}",
	);
	push @cmd, ($o{ca_file} && !$o{insecure}) ? ('--cacert', $o{ca_file}) : ('-k');

	my $stdin;
	if (defined $o{token}) {
		push @cmd, '-H', '@-';
		$stdin = "X-Vault-Token: $o{token}\n";
	}
	if (defined $o{stdin_body}) {
		push @cmd, '-H', 'Content-Type: application/json', '--data-binary', '@-';
		$stdin = $o{stdin_body};
	} elsif (defined $o{body}) {
		push @cmd, '-H', 'Content-Type: application/json', '--data-binary', $o{body};
	}
	push @cmd, "$url/v1/$o{path}";

	my ($out, $rc, $err) = run(
		{stderr => 0, redact_output => 1, (defined($stdin) ? (stdin => $stdin) : ())},
		@cmd
	);
	return (undef, ($err // '') =~ s/\s+$//r || "curl exited $rc") if $rc;
	$out //= '';
	my ($body, $code) = $out =~ /\A(.*?)\n?(\d{3})\z/s;
	return (undef, 'no HTTP status in the curl output') unless defined $code;
	return ($code, $body);
}

# }}}
# openbao_json - decode a JSON body, or undef {{{
sub openbao_json {
	my ($class, $body) = @_;
	return undef unless defined($body) && $body =~ /\S/;
	my $data = eval { JSON::PP->new->allow_nonref->decode($body) };
	return ref($data) eq 'HASH' ? $data : undef;
}

# }}}
# openbao_seal_status - GET sys/seal-status, decoded {{{
# Returns the decoded hash (type, sealed, initialized, migration,
# recovery_seal, t, n, version, ...), or undef when unreachable.
sub openbao_seal_status {
	my ($class, $env, %o) = @_;
	my ($code, $body) = $class->openbao_request($env,
		path => 'sys/seal-status', timeout => $o{timeout} // 5,
		($o{ca_file} ? (ca_file => $o{ca_file}) : (insecure => 1)),
	);
	return undef unless defined($code) && $code eq '200';
	return $class->openbao_json($body);
}

# }}}
# openbao_vault_secret - read a secret's keys exactly as stored {{{
#
# Returns a hashref of key => value for <secrets_base><relpath>, or undef
# when the path does not exist or cannot be read.  The vault's get method
# trims trailing whitespace from what it reads, which would hide the very
# defect the seal checks look for (OpenBao rejects a key file with a
# trailing newline), so this reads the JSON export, which keeps every byte.
# The output is redacted from Genesis debug and trace logs.
sub openbao_vault_secret {
	my ($class, $env, $relpath, $vault) = @_;
	my $data = eval {
		$vault //= $env->vault;
		my $path = ($env->secrets_base.$relpath) =~ s{/{2,}}{/}gr =~ s{^/+}{}r;
		return undef unless $vault->has($path);
		my ($out, $rc) = $vault->query({redact_output => 1, stderr => 0}, 'export', $path);
		return undef if $rc;
		my $json = JSON::PP->new->decode($out);
		return undef unless ref($json) eq 'HASH';
		my ($entry) = grep {ref($_) eq 'HASH'}
			($json->{$path} // $json->{"/$path"} // (values(%$json) == 1 ? values(%$json) : ()));
		$entry;
	};
	return ref($data) eq 'HASH' ? $data : undef;
}

# }}}
# openbao_static_key_problem - why a stored static key is unusable {{{
#
# Returns undef for a usable key, or a sentence that describes the problem
# without quoting the value.  OpenBao 2.7 reads the key file as is: a hex key
# with surrounding whitespace, such as the newline `echo` adds, fails startup
# with "unknown encoding for AES-256 key".
sub openbao_static_key_problem {
	my ($class, $key) = @_;
	return "it is empty" unless defined($key) && $key ne '';
	return "it has surrounding whitespace (".length($key)." characters stored); ".
	       "store it again with printf %s, never echo"
		if $key =~ /\A\s|\s\z/;
	return "it is ".length($key)." characters long, not 64" unless length($key) == 64;
	return "it is not lowercase hex (0-9, a-f)" unless $key =~ /\A[0-9a-f]{64}\z/;
	return undef;
}

# }}}
# openbao_static_key_id - derive the release's id for a hex static key {{{
# "sha256-" followed by the first 16 hex characters of the SHA-256 of the
# decoded key bytes, which is how release 0.4.0 derives current_key_id.
# Returns undef unless the key is exactly 64 lowercase hex characters.
sub openbao_static_key_id {
	my ($class, $key) = @_;
	return undef unless defined($key) && $key =~ /\A[0-9a-f]{64}\z/;
	require Digest::SHA;
	return 'sha256-'.substr(Digest::SHA::sha256_hex(pack('H*', $key)), 0, 16);
}

# }}}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
