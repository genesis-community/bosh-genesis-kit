package Genesis::Hook::CpiConfig::Bosh v3.2.0;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::CpiConfig); # Will be Genesis::Hook::CpiConfig) once that exists

use Genesis qw//;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.15');
	return $obj;
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	# There is no CPI config if the environment is not using OCFP
	$self->done() unless ($self->env->is_ocfp);

	# FIXME: bosh-configs.cpi.enabled == false can be used to disable the generation of cpi config
	#        However, we might still need to have shadow networking azs (see cloud-config.pm)

	# The CPI config should be based on what type of IaaS we're using
	my $config = $self->build_cpi_config_for_iaas(
		'openstack' => sub {
			my $config = $self->gather_properties(qw/
				!project
				!project_id
				project_domain_name@domain
				region:RegionOne
				user_domain_name@domain
				!auth_url
				username
				!api_key@password
				boot_from_volume:true
				connection_read_timeout:1500>connection_options.read_timeout
				default_key_name:ocfp
				default_security_groups:["bosh"]
				default_volume_type:storage_premium_perf2
				human_readable_vm_names:true
				root_disk_size:30>root_disk.size
				state_timeout:600
				use_dhcp:true
			/);
		},
		'vsphere' => sub {
		},
		'aws' => sub {
		},
	);
	$self->done($config);
}

1;
