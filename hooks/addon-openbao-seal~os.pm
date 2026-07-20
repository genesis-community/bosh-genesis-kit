package Genesis::Hook::Addon::BOSH::OpenbaoSeal v4.1.0;

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
		"Seal the colocated OpenBao server, preventing all further access ".
		"until it is unsealed again.\n".
		"WARNING: everything served by this OpenBao becomes unavailable ".
		"until #C{openbao-unseal} is run.";
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
	my $target = $env->name . '-openbao';

	info("");
	{
		local $ENV{SAFE_TARGET} = "";
		my ($out, $rc) = run(
			'safe', 'target', '--no-strongbox', $url, '-k', $target
		);
		bail("Failed to target OpenBao at %s:\n%s", $url, $out) if $rc;
	}

	run({interactive => 1}, 'safe', '-T', $target, 'seal');
	return $self->done();
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
