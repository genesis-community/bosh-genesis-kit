package Genesis::Hook::CloudConfigDirector::BOSH v4.0.6;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use parent qw(Genesis::Hook::CloudConfig::Director);

use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	# Given we have:
	#   /secrets/config/<env>/<ocfp-type>/vpc/azs/<n>
	# containing records like:
	#   index: <az-index>
	#   cloud_properties: { <iaas-az-cloud-properties> } # optional
	my $use_virtual_azs = $self->env->lookup('bosh-configs.virtual_azs', $self->FALSE);
	my $config = $self->build_cloud_config({
		'azs' => [
			$self->build_az_definitions(
				virtual => $self->for_iaas({
					openstack => $use_virtual_azs,
					stackit   => $use_virtual_azs,
					aws       => $use_virtual_azs
				}),
			),
		],
		'networks' => [
			$self->network_definition('compilation', strategy => 'ocfp',
				dynamic_subnets => {
					subnets => ['ocfp-2'],
					allocation => {
						size => 6,
						statics => 0,
					},
					cloud_properties_for_iaas => {
						openstack => {
							'net_id' => $self->network_reference('id'), # TODO: $self->subnet_reference('net_id'),
							'security_groups' => ['default'] #$self->subnet_reference('sgs', 'get_security_groups'),
						},
						stackit => {
							'net_id' => $self->network_reference('id'),
							'subnet_id' => $self->subnet_reference('id'),
							'security_groups' => $self->get_network_security_groups(),
						},
						aws => {
							'subnet' => $self->subnet_reference('id'),
							'security_groups' => $self->get_network_security_groups(),
						},
					},
				},
			)
		],
		'vm_types' => [
			$self->vm_type_definition('compilation',
				cloud_properties_for_iaas => {
					openstack => {
						'instance_type' => 'm1.2',
						'boot_from_volume' => $self->TRUE,
						'root_disk' => {
							'size' => 30 # in gigabytes
						}
					},
					stackit => {
						'instance_type' => 'g1a.4d',
						'boot_from_volume' => $self->TRUE,
						'root_disk' => {
							'size' => 30 # in gigabytes
						}
					},
					aws => {
						'instance_type' => $self->for_scale({
							dev => 't3.medium',
							prod => 't3.large',
						}, 't3.medium'),
						'ephemeral_disk' => {
							'size' => $self->for_scale({
								dev => 32768,
								prod => 65536
							}, 32768),
							'type' => 'gp3',
							'encrypted' => $self->TRUE
						},
					},
				},
			),
		],
		compilation => {
			$self->compilation_definition(
				strategy => 'ocfp',
				persistent_disk_type => undef
			)
		},
	});

	$self->done($config);
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
