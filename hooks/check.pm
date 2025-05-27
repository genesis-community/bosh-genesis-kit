#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 noet:
package Genesis::Hook::Check::Bosh v3.3.0; # version of the bosh kit

use strict;
use warnings;
use v5.20; # Genesis supports min perl v5.20.

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

# Parent class inheritance
use parent qw(Genesis::Hook::Check);

# Import required functions
use Genesis qw/bail info warning error in_array new_enough/;

sub init {
	my ($class, %ops) = @_;
	my $obj = $class->SUPER::init(%ops);
	$obj->check_minimum_genesis_version('3.1.0-rc.24');
	return $obj;
}

sub perform {
	my ($self) = @_;
	my $ok = 1;

	# Version compatibility checks
	$ok = 0 unless $self->check_version_compatibility();

	# Cloud Config checks
	$ok = 0 unless $self->check_cloud_config();

	# Environment Parameter checks
	$ok = 0 unless $self->check_environment_parameters();

  return $self->done();
}

sub check_cloud_config {
	my ($self) = @_;

	$self->start_check('cloud_config');

	return $self->check_result('cloud-config', 'skipped', "create env") if $self->use_create_env;
	return $self->check_result('cloud-config', 'skipped', "OCFP env") if $self->is_ocfp;
	return $self->check_result('cloud-config', 'failed', "no cloud config found") if $self->env->has_config('no_cloud');

	my ($vm_type, $network, $disk_type);
	my $env = $self->env;

	# Legacy was hard coded
	$vm_type = "large";
	$network = "bosh";
	$disk_type = "bosh";

	$self->has_entry('cloud-config','vm_type', $vm_type);
	$self->has_entry('cloud-config','network', $network);
	$self->has_entry('cloud-config','disk_type', $disk_type);
	return $self->check_result('cloud-config');
}

sub check_environment_parameters {
	my ($self) = @_;

	$self->start_check('environment');
	if ($self->want_feature("vsphere")) {
		for my $ds_type (qw(ephemeral persistent)) {
			my $param_name = "vsphere_${ds_type}_datastores";
			$self->has_entry('environment', 'params', $param_name, type => 'array', msg => 'is an array');
		}
	} else {
		# TODO: Should we just skip environment checks if vsphere is not enabled, with no output?
		return $self->check_result('environment', 'skipped', "no vsphere feature");
	}
}

sub check_version_compatibility {
	my ($self) = @_;
	my $last_version = $self->exodus_data->{kit_version};
	if ($last_version) {
		if (!new_enough($last_version, "3.0.0")) {
			$self->start_check('version upgrade compatibility');
			if (!new_enough($last_version, "2.3.0")) {
				return $self->check_result(
					'version upgrade compatibility',
					'warning',
					"Forcing incompatible upgrade due to FORCE_INCOMPATIBLE_UPGRADE being set",
				) if $self->env->exodus_lookup('FORCE_INCOMPATIBLE_UPGRADE', '');
				return $self->check_result(
					'version upgrade compatibility',
					'failed',
					"Please upgrade to at least bosh kit 2.3.0 before upgrading to v3.x.x",
				);
			}
			return $self->check_result('version upgrade compatibility', 'passed')
		}
	}
	return 1;
}

1;
