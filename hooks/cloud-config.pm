package Genesis::Hook::CloudConfig::Bosh v3.3.0;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::CloudConfig);

use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use Genesis qw/uniq/;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.4');
	return $obj;
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	# Need to determine if the environment wants to use a custom CPI.  If it does,
	# we need to use custom AZs that are a shadow version of the parent AZs that
	# use the CPI (if not create-env), and then the network has to use those AZs.

	my $config = $self->build_cloud_config({
		$self->build_cpi_azs(
			virtual => scalar($self->env->lookup('bosh-configs.virtual_azs', $self->FALSE)),
		),
		'vm_extensions' => [
			$self->vmx_for_iaas('bosh-lbs' => {
				aws => {
					'lb_target_groups' => [$self->env->lookup(
						'bosh-configs.cloud.bosh-lb-target-group',
						'ocfp-' . ( $ENV{GENESIS_ENVIRONMENT} || 'mgmt' ) . '-bosh-lb-tg'
					)]
				}
			})
		],
		'networks' => [
			# FIXME: strategy should be defined by the environment, not the kit
			$self->network_definition('bosh', strategy => 'ocfp',
				dynamic_subnets => {
					allocation => {
						size => 0,
						statics => 0,
					},
					cloud_properties_for_iaas => {
						aws => {
              #'net_id' => $self->network_reference('id'),
							'subnet' => $self->subnet_reference('id'),
							'security_groups' => $self->network_reference('sgs', 'get_network_sgs_ids'),
						},
						openstack => {
							'net_id' => $self->network_reference('id'), # TODO: $self->subnet_reference('net_id'),
							'security_groups' => ['default'] #$self->subnet_reference('sgs', 'get_security_groups'),
						},
						stackit => {
							'net_id' => $self->network_reference('id'),
							'security_groups' => $self->network_reference('sgs', 'get_sgs_by_names', 'ocfp', 'default')
						},
					},
				},
			)
		],
		'vm_types' => [
			$self->vm_type_definition('bosh',
				cloud_properties_for_iaas => {
					aws => {
						'instance_type' => $self->for_scale({
							dev => 't3.large',
							prod => 'm6i.2xlarge'
						}, 't3.large'),
						'ephemeral_disk' => {
							'size' => $self->for_scale({
								dev => gigabytes(64),
								prod => gigabytes(128)
							}, gigabytes(64)),
							'type' => 'gp3',
							'encrypted' => $self->TRUE
						},
						'metadata_options' => {
							'http_tokens' => 'required'
						}
					},
					openstack => {
						'instance_type' => $self->for_scale({
							dev => 'm1.2',
							prod => 'm1.3'
						}, 'm1.2'),
						'boot_from_volume' => $self->TRUE,
						'root_disk' => {
							'size' => 32 # in gigabytes
						},
					},
					stackit => {
						'instance_type' => $self->for_scale({
							dev => 'm1.2',
							prod => 'm1.3'
						}, 'm1.2'),
						'boot_from_volume' => $self->TRUE,
						'root_disk' => {
							'size' => 32 # in gigabytes
						},
					},
				},
			),
		],
		'disk_types' => [
			$self->disk_type_definition('bosh',
				common => {
					disk_size => $self->for_scale({ # add $self->for_feature('internal-blobstore')
						dev => gigabytes(32),
						prod => gigabytes(256)
					}, gigabytes(32)),
				},
				cloud_properties_for_iaas => {
					aws => {
						'type' => 'gp3',
						'encrypted' => $self->TRUE
					},
					openstack => {
						'type' => 'storage_premium_perf6',
					},
					stackit => {
						'type' => 'storage_premium_perf6',
					},
				},
			),
		],
	});

	$self->done($config);
}

sub get_sgs_by_names {
        my ($self, $subnet_data, $ref, @names) = @_;
        my @ids = map {$subnet_data->{$ref}{$_}{id}} @names;
        # TODO: Error checking
        return \@ids
}

sub get_network_sgs_ids {
	my ($self, $network_data, $ref) = @_;
	my $sgs = $network_data->{sgs} || {};
	my @ids = uniq map {$sgs->{$_}{id}} keys %$sgs;
	return \@ids;
}

sub vmx_for_iaas {
	my ($self, $name, $data) = @_;
	return () unless exists($data->{$self->env->iaas});
	my $iaas_data = $data->{$self->env->iaas} || {};
	return "$name" unless $iaas_data; # Create vmx without cloud properties

	my $cloud_properties = $data->{$self->env->iaas};
	return {
		name => $name,
		cloud_properties => $self->_process_config_overrides(
			Genesis::Hook::CloudConfig::VM_EXTENSION, $name, $cloud_properties, 'cloud_properties'
		),
	};
}

1;
# vim: set ts=2 sw=2 sts=2 noet:
