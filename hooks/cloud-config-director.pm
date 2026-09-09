package Genesis::Hook::CloudConfigDirector::BOSH v4.1.0;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use parent qw(Genesis::Hook::CloudConfig::Director);

use Genesis qw/bail/;
use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	# 3.2.0-rc.16 is the first published Genesis release whose base
	# AZ-definition loop calls cpi_name_for_az.  On anything older the
	# override below is simply never invoked: az_map is silently
	# ignored and every AZ falls back to the single cpi_name, which is
	# valid cloud-config for the wrong topology.  Fail loudly instead.
	$obj->check_minimum_genesis_version('3.2.0-rc.16');
	return $obj;
}

# cpi_name_for_az - Resolves the CPI name to use for a given AZ key {{{
sub cpi_name_for_az {
	my ($self, $az_key, $az_data) = @_;

	# Overrides the base extension point (Genesis::Hook::CloudConfig) to
	# resolve a per-AZ CPI name from bosh-configs.director-cpi.az_map when
	# present; otherwise fall through to the existing single-CPI-per-director
	# default, so every env that doesn't declare az_map renders byte-identical
	# cloud-config to today.
	my $az_map = $self->env->lookup('bosh-configs.director-cpi.az_map', {});
	return $az_map->{$az_key} if ref($az_map) eq 'HASH' && defined($az_key) && exists $az_map->{$az_key};
	return $self->cpi_name;
}

# }}}
# _validate_az_map_keys - Fail loud when az_map has a key with no matching AZ {{{
sub _validate_az_map_keys {
	my ($self, $azs) = @_;

	# az_map is keyed by the OCFP vault AZ key names (net/azs/*, e.g. pvea,
	# pved), which is exactly the set of keys get_available_azs returns. A
	# key that doesn't match one of those (most commonly a copy-pasted
	# rendered `-zN` name instead of the vault key) used to be silently
	# ignored -- every AZ it was meant to cover fell through to the default
	# single CPI with no error (wrong-cluster placement, undetected). Bail
	# instead of silently no-op-ing so a bad az_map is a config error, not a
	# placement bug discovered later.
	my $az_map = $self->env->lookup('bosh-configs.director-cpi.az_map', {});
	return unless ref($az_map) eq 'HASH' && %$az_map;

	my @valid_keys = sort keys %$azs;
	my %valid = map { $_ => 1 } @valid_keys;
	my @unknown_keys = sort grep { !$valid{$_} } keys %$az_map;
	return unless @unknown_keys;

	bail(
		"bosh-configs.director-cpi.az_map has unknown AZ key(s): %s. ".
		"az_map keys must be the OCFP vault az keys (net/azs/*), not the ".
		"rendered -zN names. Valid az keys for this environment: %s",
		join(', ', map {"'$_'"} @unknown_keys),
		(@valid_keys ? join(', ', map {"'$_'"} @valid_keys) : '(none available)'),
	);
}

# }}}
# build_az_definitions - Validates az_map, then defers to the base loop {{{
sub build_az_definitions {
	my ($self, %options) = @_;

	# The base loop injects per-AZ `cpi:` via our cpi_name_for_az override;
	# this wrapper only adds the fail-loud az_map key check before it runs.
	$self->_validate_az_map_keys(scalar $self->get_available_azs) if $self->cpi_enabled;
	return $self->SUPER::build_az_definitions(%options);
}

# }}}
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
						size => 4,
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
					pve => {
						'cpu'            => scalar($self->env->lookup('bosh-configs.cpi.pve_compilation_cpu', 2)),
						'ram'            => scalar($self->env->lookup('bosh-configs.cpi.pve_compilation_ram', 4096)),
						'disk'           => scalar($self->env->lookup('bosh-configs.cpi.pve_compilation_disk', 32768)),
						'network_bridge' => $self->_pve_cpi_setting('pve_network_bridge', 'network_bridge', 'vmbr0'),
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
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
