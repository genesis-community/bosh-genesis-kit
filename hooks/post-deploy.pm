package Genesis::Hook::PostDeploy::Bosh v3.2.0;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use Genesis qw//;
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

		success("#M{%s} BOSH Director deployed!", $env->name);

		# Run the director-cloud-config hook to generate and apply the cloud-config
		$env->notify("Generating the Network space for the BOSH Director");
		info({pending => 1}, "[[  - >>building director cloud-config...");
		my $tstart = gettimeofday;
		my ($config, $network) = $env->run_hook('cloud-config', purpose => 'director');
		info("#G{done}".pretty_duration(gettimeofday - $tstart, 5, 10));

		# FIXME: Do a check and compare, and ask if different (or just do it if $BOSH_NON_INTERACTIVE is set)
		# or at least show the diff (maybe too late to ask if bosh is already deployed)
		info({pending => 1}, "[[  - >>applying director cloud-config...");
		my $bosh = $self->get_target_bosh(self => 1);
		my $config_name = join('.',$env->name, $env->deployment_type, 'director');
		$tstart = gettimeofday;
		$bosh->upload_config('cloud', $config_name, $config);
		info("#G{done}".pretty_duration(gettimeofday - $tstart, 5, 10));

		info({pending => 1}, "[[  - >>storing director network in exodus...");
		$tstart = gettimeofday;
		$self->vault->set_path($env->exodus_base.'/networks', $network, flatten => 1);
		info("#G{done}".pretty_duration(gettimeofday - $tstart, 1, 3));
		info('[[  - >>#M{%s} BOSH Director cloud-config applied.', $env->name);

		# Upload the runtime configs
		# TODO: Implement this
		
		# Upload a stemcell if there aren't any
		# TODO: Implement this

		# Provide usage assistance (aka help)
		info(
			"For details about the deployment, run\n".
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
