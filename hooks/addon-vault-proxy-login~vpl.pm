package Genesis::Hook::Addon::BOSH::VaultProxyLogin v4.1.0;

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
	return "Target and log into credhub via vault proxy using safe.";
}

# }}}
# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;
	my $env = $self->env;

	# Check if the vault-credhub-proxy feature is wanted
	if (!$env->has_feature('vault-credhub-proxy')) {
		bail("#R{[ERROR]} Requires feature vault-credhub-proxy");
	}

	info("");

	# Get IP address
	my $host = $self->exodus_data->{url} =~ s{^https?://}{}r =~ s{:[0-9]+$}{}r;
	my $proxy = $env->name . "-proxy";

	# Get password from vault
	my $password = $self->vault->get($env->secrets_base() . "uaa/clients/credhub_admin:secret");

	# Target vault proxy
	$ENV{SAFE_TARGET} = "";
	my ($out, $rc, $err) = run("safe target \"https://$host:8200\" -k --no-strongbox \"$proxy\"");
	bail("Failed to target vault proxy: $err") if $rc;

	# Authenticate
	($out, $rc, $err) = run("echo \"credhub-admin:$password\" | safe -T \"$proxy\" auth token");
	bail("Failed to authenticate with vault proxy: $err") if $rc;

	# Test connection
	($out, $rc, $err) = run("safe -T \"$proxy\" set secret/handshake knock=knock >/dev/null 2>&1");
	bail("#R{[ERROR]} Authentication failed or could not write to secret/") unless $rc == 0;

	($out, $rc, $err) = run("safe -T \"$proxy\" read secret/handshake >/dev/null 2>&1");
	bail("#R{[ERROR]} Could not read from Credhub Vault Proxy on $host") unless $rc == 0;

	info(
		"Successfully connected to Credhub Vault Proxy on #C{https://%s:8200}\n".
		"Target name is #C{%s}\n", $host, $proxy
	);

	return $self->done();
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
