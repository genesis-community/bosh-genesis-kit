package Genesis::Hook::CloudConfig::BOSH v4.1.0;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::CloudConfig);

use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use Genesis qw/uniq bail/;
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
		# FIXME: should be able to define vm_extension according to environment name
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
							'security_groups' => $self->get_network_security_groups(),
						},
						openstack => {
							'net_id' => $self->network_reference('id'), # TODO: $self->subnet_reference('net_id'),
							'security_groups' => ['default'] # need to add get_subnet_security_groups method
						},
						stackit => {
							'net_id' => $self->network_reference('id'),
							'security_groups' => $self->get_network_security_groups(),
						},
						pve => {
							'bridge' => $self->_pve_cpi_setting('pve_network_bridge', 'network_bridge', 'vmbr0'),
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
							dev => 'g1a.4d',
							prod => 'g1a.8d',
						}, 'm1a.4d'),
						'boot_from_volume' => $self->TRUE,
						'root_disk' => {
							'size' => 32, # in gigabytes
							'type' => 'storage_premium_perf6'
						},
					},
					pve => {
						'cpu'            => scalar($self->env->lookup('bosh-configs.cpi.pve_bosh_cpu', $self->for_scale({ dev => 2, prod => 4 }, 2))),
						'ram'            => scalar($self->env->lookup('bosh-configs.cpi.pve_bosh_ram', $self->for_scale({ dev => 4096, prod => 8192 }, 4096))),
						'disk'           => scalar($self->env->lookup('bosh-configs.cpi.pve_bosh_disk', $self->for_scale({ dev => 32768, prod => 65536 }, 32768))),
						'network_bridge' => $self->_pve_cpi_setting('pve_network_bridge', 'network_bridge', 'vmbr0'),
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
					pve => {
						'storage'     => $self->_pve_cpi_setting('pve_disk_storage', 'disk_storage', 'local-lvm'),
						'disk_format' => scalar($self->env->lookup('bosh-configs.cpi.pve_disk_format', 'raw')),
					},
				},
			),
		],
	});

	$self->done($config);
}


# _pve_cpi_setting - resolve a PVE CPI setting from the env file, then the OCFP vault config, then a default {{{
sub _pve_cpi_setting {
	my ($self, $env_key, $vault_key, $default) = @_;
	my $value = scalar($self->env->lookup("bosh-configs.cpi.$env_key", undef));
	$value //= scalar($self->env->ocfp_config_lookup("cpi.pve.$vault_key", undef));
	$value //= $default;
	bail(
		"No PVE %s configured for %s: set #c{bosh-configs.cpi.%s} in the ".
		"environment file, or run #g{ocfp vault populate} so the OCFP config ".
		"provides #c{cpi/pve:%s}.",
		$vault_key, $self->env->name, $env_key, $vault_key
	) unless defined($value) && length($value);
	return $value;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet:
