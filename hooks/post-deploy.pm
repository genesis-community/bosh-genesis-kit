package Genesis::Hook::PostDeploy::BOSH v4.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info/;

# init - Initialize the hook and check minimum Genesis version {{{
sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.4');
	return $obj;
}

# }}}

# deploy_successful - Check if deployment was successful {{{
sub deploy_successful {
	my $self = shift;
	return ($self->{rc} // 255) == 0;
}

# }}}

# perform - Execute post-deployment tasks for BOSH environments {{{
sub perform {
	my ($self) = @_;
	if ($self->deploy_successful) {
		my $env = $self->env;

		# Update the BOSH CPI config
		$self->upload_director_cpi_config();

		# Update the director cloud config and network mappings
		$self->update_director_network_config();

		# Upload the runtime configs
		$self->upload_runtime_configs();

		# Upload a stemcell if there aren't any
		$self->upload_stemcells();

		# Provide usage assistance (aka help)
		my $usage = '';
		my @usage_args = ();
		my $need_self = $self->env->use_create_env ? '' : ' --self';
		my $cmd_with_env = $self->env->get_call_path_with_env();
		$usage .= "\n".
			"For details about the deployment, run\n".
			"[[  >>#G{%s info}\n\n".
			"To run bosh command against this BOSH director, as an adminstrator, run\n".
			"[[  >>#G{%s bosh$need_self <cmd> <options>}\n\n".
			"You can upload stemcells (you'll need at least one) by running\n".
			"[[  >>#G{%s do upload-stemcells}\n\n".
			"This BOSH director provides a Credhub secrets store.\n\n".
			"You can run credhub commands directly through Genesis by running\n".
			"[[  >>#G{%s credhub$need_self <cmd> <options>}\n\n";
		@usage_args = ($cmd_with_env) x 4;

		if ($env->has_feature('vault-credhub-proxy')) {
			$usage .=
				"It also provides a vault-credhub-proxy server, which allows you to ".
				"access credhub via #C{safe}.  To login, run\n".
				"[[  >>#G{%s do vault-proxy-login}\n\n";
			push @usage_args, $cmd_with_env
		}
		info($usage, @usage_args);
	}
	return $self->done(1);
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
