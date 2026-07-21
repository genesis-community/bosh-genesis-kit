package Genesis::Hook::Addon::BOSH::OpenbaoTarget v4.1.0;

use v5.20; # Genesis min perl version is 5.20
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info run/;

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
		"Target the colocated OpenBao server and authenticate via the given ".
		"auth method (default: token), interactively if needed.\n".
		"Usage: openbao-target [METHOD]";
}

# }}}
# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;
	my $env = $self->env;

	bail("#R{[ERROR]} Requires feature openbao")
		unless $env->has_feature('openbao');

	my $method = $self->{args}[0] || 'token';
	my $ip     = $env->lookup('params.static_ip')
		or bail("params.static_ip is not set for this environment");
	my $port   = $env->lookup('params.openbao_port', 8200);
	my $url    = "https://$ip:$port";
	# Target name must be exactly the env name: genesis (one target per URL)
	# and `ocfp vault migrate` (looks up target "<env>") both key on it.
	my $target = $env->name;

	info("");
	{
		local $ENV{SAFE_TARGET} = "";
		my ($out, $rc) = run(
			'safe', 'target', '--no-strongbox', $url, '-k', $target
		);
		bail("Failed to target OpenBao at %s:\n%s", $url, $out) if $rc;
	}

	info("Authenticating with the #C{%s} auth method...", $method);
	my (undef, $auth_rc) = run(
		{interactive => 1}, 'safe', '-T', $target, 'auth', $method
	);
	if ($auth_rc != 0) {
		info("#R{Authentication failed} (exit code %s)", $auth_rc);
		return $self->done(0);
	}

	my (undef, $h_rc) = run(
		{stderr => 0}, 'safe', '-T', $target, 'exists', 'secret/handshake'
	);
	if ($h_rc == 0) {
		info(
			"OpenBao at #C{%s} is targeted as #C{%s} and authenticated.",
			$url, $target
		);
		return $self->done(1);
	}

	info("Authenticated, but #C{secret/handshake} is missing or unreadable.");
	return $self->done(0);
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
