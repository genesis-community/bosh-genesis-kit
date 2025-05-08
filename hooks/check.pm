#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 et:
package Genesis::Hook::Check::Bosh v3.3.0; # version of the bosh kit

use strict;
use warnings;
use v5.20; # Genesis supports min perl v5.20.

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

# Parent class inheritance
use parent qw(Genesis::Hook);

# Import required functions
use Genesis qw/bail info warning error in_array new_enough/;

sub init {
  my ($class, %ops) = @_;
  my $obj = $class->SUPER::init(%ops);
  $obj->{ok} = 1; # Start assuming all checks will pass
	$obj->{files} = [];
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
  return $obj;
}

sub perform {
  my ($self) = @_;

  # Check Genesis version
  $self->check_genesis_version();

  # Cloud Config checks
  $self->check_cloud_config() if $ENV{GENESIS_CLOUD_CONFIG};

  # Environment Parameter checks
  $self->check_environment_parameters();

  # Version compatibility checks
  $self->check_version_compatibility();

  # Return the final result
  if ($self->{ok}) {
    $self->env->notify(success => "environment files [#G{OK}]");
  } else {
    $self->env->notify(error => "environment files [#R{FAILED}]");
  }

  return $self->done($self->{ok});
}

sub check_genesis_version {
  my ($self) = @_;

  unless (new_enough($Genesis::VERSION, "2.8.6")) {
    $self->{ok} = 0;
    trace("Genesis version check failed - need at least 2.8.6");
  }
}

sub check_cloud_config {
  my ($self) = @_;

  my $env = $self->env;
  my ($vm_type, $network, $disk_type);

  if ($env->want_feature("ocfp")) {
    my $prefix = $env->lookup("params.cloud_config_prefix");
    $prefix = "$env->{name}.$env->{type}" unless $prefix;

    $vm_type = "$prefix.vm-bosh";
    $network = "$prefix.net-bosh";
    $disk_type = "$prefix.disk-bosh";
  } else {
    # Legacy was hard coded
    $vm_type = "large";
    $network = "bosh";
    $disk_type = "bosh";
  }

  if (!$env->use_create_env) {
    # Call the cloud_config_needs function for each requirement
    # These appear to be implemented elsewhere in Genesis
    run("cloud_config_needs vm_type \"" . $env->lookup("params.bosh_vm_type", $vm_type) . "\"");
    run("cloud_config_needs network \"" . $env->lookup("params.bosh_network", $network) . "\"");
    run("cloud_config_needs disk_type \"" . $env->lookup("params.bosh_disk_pool", $disk_type) . "\"");

    if (system("check_cloud_config") == 0) {
      $self->env->notify("  cloud-config [#G{OK}]");
    } else {
      $self->env->notify("  cloud-config [#R{FAILED}]");
      $self->{ok} = 0;
    }
  }
}

sub check_environment_parameters {
  my ($self) = @_;

  my $env = $self->env;

  if ($env->want_feature("vsphere")) {
    for my $ds_type (qw(ephemeral persistent)) {
      my $param_name = "params.vsphere_${ds_type}_datastores";
      my $type = $env->lookup("$param_name.__type", '');

      if ($type ne "list") {
        $type = ref($env->lookup($param_name)) eq 'ARRAY' ? 'list' : $type || 'scalar';
        $self->env->notify("  ${ds_type} vsphere datastores is a #Y{$type}, not a list [#R{FAILED}]");
        $self->{ok} = 0;
      } else {
        $self->env->notify("  ${ds_type} vsphere datastores checks out [#G{OK}]");
      }
    }
  }
}

sub check_version_compatibility {
  my ($self) = @_;

  my $env = $self->env;
  my $version = $env->exodus_lookup("kit_version", "");

  if ($version) {
    if (!new_enough($version, "3.0.0")) {
      $self->env->notify("  #C{[Checking Upgrade from $version]}");

      if (!new_enough($version, "2.2.7-rc.0")) {
        $self->env->notify("    #R{[ERROR]} Please upgrade to at least bosh kit 2.3.0 before upgrading to v3.x.x");

        if ($ENV{FORCE_INCOMPATIBLE_UPGRADE}) {
          $self->env->notify("    #y{[WARN]} Forcing incompatible upgrade due to FORCE_INCOMPATIBLE_UPGRADE being set");
        } else {
          $self->{ok} = 0;
        }
      }
    }
  }
}

1;
