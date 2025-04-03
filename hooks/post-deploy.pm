package Genesis::Hook::PostDeploy::Bosh v3.2.0;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use Genesis qw/info/;
use JSON::PP;
use Time::HiRes qw/gettimeofday/;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.4');
	return $obj;
}

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
		info(
			"\nFor details about the deployment, run\n".
			"  #G{$ENV{GENESIS_CALL_ENV} info}\n".
			"\n".
			"To run bosh command against this BOSH director, as the admin user, run\n".
			"  #G{$ENV{GENESIS_CALL_ENV} bosh --self <cmd> <options>}\n".
			"\n".
			"This BOSH director provides a Credhub secrets store.\n".
			"You can run credhub commands directly through Genesis by running\n".
			"  #G{$ENV{GENESIS_CALL_ENV} credhub --self <cmd> <options>}\n".
			"\n".
			"You can upload stemcells (you'll need at least one) by running\n".
			"  #G{$ENV{GENESIS_CALL_ENV} do upload-stemcells}\n\n"
		);

		if ($env->has_feature('vault-credhub-proxy')) {
			info(
				"It also provides a vault-credhub-proxy server, which allows you to ".
				"access credhub via #C{safe}.  To login, run".
				"   #G{$ENV{GENESIS_CALL_ENV} do vault-proxy-login}\n\n"
			);
		}
	}

	$self->done;
}
1;
