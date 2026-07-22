package Genesis::Hook::CloudConfigDirector::BOSH v4.1.0;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use parent qw(Genesis::Hook::CloudConfig::Director);

use Genesis qw/uniq bail/;
use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}

# _cpi_name_for_az - Resolves the CPI name to use for a given AZ key {{{
sub _cpi_name_for_az {
	my ($self, $az_name) = @_;

	# Resolve a per-AZ CPI name from bosh-configs.director-cpi.az_map when
	# present; otherwise fall through to the existing single-CPI-per-director
	# default, so every env that doesn't declare az_map renders byte-identical
	# cloud-config to today.
	my $az_map = $self->env->lookup('bosh-configs.director-cpi.az_map', {});
	return $az_map->{$az_name} if ref($az_map) eq 'HASH' && exists $az_map->{$az_name};
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
# build_az_definitions - Overrides base to allow per-AZ CPI selection via az_map {{{
sub build_az_definitions {
	my ($self, %options) = @_;

	# Same shape/loop as the base class (Genesis::Hook::CloudConfig::Director),
	# except the injected `cpi:` per AZ comes from _cpi_name_for_az($az_name)
	# instead of the base's single $self->cpi_name for every entry. $az_name is
	# available here because this method owns the loop over get_available_azs
	# directly, unlike _az_definition_for, which only ever receives the per-AZ
	# data hashref, never the original key.
	#
	# DRIFT RISK: this duplicates the loop body of
	# Genesis::Hook::CloudConfig::Director::build_az_definitions (genesis
	# lib/Genesis/Hook/CloudConfig/Director.pm).  Changes to the base loop
	# (AZ filtering, sorting, definition shape) will NOT reach this kit;
	# re-diff against the base method whenever upgrading Genesis, until the
	# base grows a per-AZ cpi extension point and this override can shrink
	# to just _cpi_name_for_az.
	my $prefix = delete($options{prefix}) // '';

	my @azs = ();
	my $azs = $self->get_available_azs;
	$self->_validate_az_map_keys($azs) if $self->cpi_enabled;
	for my $az_name (keys %$azs) {
		next unless $azs->{$az_name}{name};
		my $config = $self->_az_definition_for($azs->{$az_name}, %options);
		$config->{cpi} = $self->_cpi_name_for_az($az_name) if $self->cpi_enabled;
		push @azs, $config;
	}
	my @results = uniq sort {$a->{name} cmp $b->{name}} @azs;
	return wantarray ? @results : \@results;
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
						'network_bridge' => scalar($self->env->lookup('bosh-configs.cpi.pve_network_bridge', 'lvnet001')),
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
