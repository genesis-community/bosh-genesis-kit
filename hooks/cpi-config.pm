package Genesis::Hook::CpiConfig::BOSH v4.0.2;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::CpiConfig);

use Genesis qw/info/;
use JSON::PP;

# Initialize hook object with necessary version checks
sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.15');
	return $obj;
}

# Generate CPI configuration based on IaaS type
sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	# There is no CPI config if the environment is not using OCFP
	$self->done() unless ($self->env->is_ocfp);

	# Check if CPI config generation is disabled
	my $cpi_enabled = $self->env->lookup('params.bosh-configs.cpi.enabled')//1; # Default to enabled
	unless ($cpi_enabled) {
		info("CPI config generation is disabled via #m{bosh-configs.cpi.enabled} = #B{false}");
		# We might still need to have shadow networking azs (see cloud-config.pm)
		return $self->done();
	}

	# The CPI config should be based on what type of IaaS we're using
	# The gather_properties methods will bail on error so no need to error check
	my $config = $self->build_cpi_config_for_iaas(
		'openstack' => sub { $self->gather_properties($self->_property_map_for_openstack) },
		'stackit'   => sub { $self->gather_properties($self->_property_map_for_stackit) },
		'vsphere'   => sub { $self->gather_properties($self->_property_map_for_vsphere) },
		'aws'       => sub { $self->gather_properties($self->_property_map_for_aws) },
	);
	$self->done($config);
}


# IaaS-specific CPI configs {{{

# OpenStack CPI configuration properties
sub _property_map_for_openstack {
	qw/
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
	/;
}

# Stackit CPI configuration - extends OpenStack with Stackit-specific properties
sub _property_map_for_stackit {
	my ($self) = @_;

	return qw/
		!project_id
		org_id
		!service_account_json
		region:eu01
		auth_url
		endpoint
		boot_from_volume:true
		connection_read_timeout:1500>connection_options.read_timeout
		default_key_name@keypair_name:ocfp
		default_security_groups:["default"]
		default_volume_type:storage_premium_perf2
		human_readable_vm_names:true
		root_disk_size:30>root_disk.size
		state_timeout:600
		use_dhcp:true
	/;
}

# vSphere CPI configuration properties
sub _property_map_for_vsphere {
	qw/
		!vcenter_address@host
		!user
		!password
		datacenters
		datacenter@datacenters.first.name
		clusters@datacenters.first.clusters
		resource_pool@datacenters.first.resource_pool
		ephemeral_datastores@datacenters.first.datastore_pattern
		persistent_datastores@datacenters.first.persistent_datastore_pattern
		folder@datacenters.first.vm_folder
		template_folder@datacenters.first.template_folder
		disk_path@datacenters.first.disk_path
		enable_auto_anti_affinity_drs_rules:true@datacenters.first.enable_auto_anti_affinity_drs_rules
		nsxt@nsxt
	/;
}

# AWS CPI configuration properties
sub _property_map_for_aws {
	qw/
		!access_key_id
		!secret_access_key
		!region
		default_key_name@keypair_name:ocfp
		default_security_groups:["bosh"]
		ec2_endpoint?
		max_retries:10
		encrypted:true
		kms_key_arn?
		iam_instance_profile?
		http_endpoint:enabled>metadata_options.http_endpoint
		http_tokens:required>metadata_options.http_tokens
		http_put_response_hop_limit?>metadata_options.http_put_response_hop_limit
	/;
	# use_v4_signature:true - disabled for now
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
