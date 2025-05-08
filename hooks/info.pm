#!/usr/bin/env perl
# # vim: set ts=2 sw=2 sts=2 et:
package Genesis::Hook::Info::Bosh v3.3.0; # ...::[KIT] v[KIT_VERSION]

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
	$obj->{files} = [];
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
  return $obj;
}

sub perform {
  my ($self) = @_;

  # Version check
  #$self->check_minimum_genesis_version('2.8.4') || return 0;
	$self->check_minimum_genesis_version('3.1.0-rc.9') || return 0;
  # TODO: Which version should we be checking?

  # Get BOSH environment info from exodus data
  my $bosh_environment = $self->env->exodus_lookup('url') || 'https://127.0.0.1:25555';
  my $bosh_ca_cert = $self->env->exodus_lookup('ca_cert');
  my $bosh_client = $self->env->exodus_lookup('admin_username');
  my $bosh_client_secret = $self->env->exodus_lookup('admin_password');

  # Display BOSH environment
  info("BOSH env");
  my ($out, $rc, $err) = run("bosh -A env --tty | sed -e 's/^/  /'");
  info($out);

  # Display access instructions
  my $call_with_env = $self->env->get_call_path_with_env();

  info(join("\n",
      "",
      "Accessing BOSH:",
      "",
      "To log into the BOSH director from the command line:",
      "  #G{$call_with_env do -- login}",
      "",
      "If you need to provide the access credentials, they are:",
      "",
      "  #i{    bosh url:} #C{$bosh_environment}",
      "  #i{    username:} #C{$bosh_client}",
      "  #i{    password:} #C{$bosh_client_secret}",
      "#i{ca certificate:}",
      "#C{$bosh_ca_cert}",
      ""
    ));

  # Check for Credhub
  my $bosh_credhub_url = $self->env->exodus_lookup('credhub_url');
  if ($bosh_credhub_url) {
    info(join("\n",
        "To log into the Credhub provided by this BOSH deployment:",
        "  #G{$call_with_env do -- credhub-login}",
        ""
      ));
  }

  # Check for vault-credhub-proxy
  my $has_vault_credhub_proxy = $self->env->exodus_lookup('has_vault_credhub_proxy');
  if ($has_vault_credhub_proxy) {
    info(join("\n",
        "To log into the Credhub via #C{safe} using the vault-credhub-proxy:",
        "  #G{$call_with_env do -- vault-proxy-login}",
        ""
      ));
  }

  return $self->done(1);
}

1;
