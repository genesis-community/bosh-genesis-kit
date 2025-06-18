#! /usr/bin/env perl
package Genesis::Hook::Addon::BOSH::CredhubLogin v3.3.0;    # ...::[KIT] v[KIT_VERSION]

use strict;
use warnings;
use v5.20;                                                  # Genesis supports min perl v5.20.

# Only needed for development
BEGIN { push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME} . '/.genesis/lib' }

# Parent class inheritance
use parent qw(Genesis::Hook::Addon);

# Import required functions
use Genesis qw/bail info warning error in_array new_enough/;

sub init {
	my ( $class, %ops ) = @_;
	my $obj = $class->SUPER::init(%ops);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
	return $obj;
}

sub cmd_details {
	return "Target and log in to credhub on this bosh director";
}

sub perform {
	my ($self) = @_;

	# Check if the credhub command is available
	# TODO: Use the Genesis built in command to check if the command exists
	my ( $out, $rc ) = run( { stderr => 0 }, "command -v credhub" );
	bail( "#R{[ERROR]} Command 'credhub' not found.  Please install from " .
		  "https://github.com/cloudfoundry-incubator/credhub-cli" )
	  if $rc;

	# Extract values from exodus data
	my $exodus       = $self->exodus_data();
	my $bosh_ca_cert = $exodus->{ca_cert}          // "";
	my $ch_ca_cert   = $exodus->{credhub_ca_cert}  // "";
	my $ch_pw        = $exodus->{credhub_password} // "";
	my $ch_url       = $exodus->{credhub_url}      // "";
	my $ch_user      = $exodus->{credhub_username} // "";

	# Unset environment variables
	delete $ENV{CREDHUB_SERVER};
	delete $ENV{CREDHUB_SECRET};
	delete $ENV{CREDHUB_CLIENT};
	delete $ENV{CREDHUB_CA_CERT};

	# Create temporary file for CA certificates
	my $ca_file = $self->env->workpath("credhub-ca.pem");
	mkfile_or_fail( $ca_file, "$bosh_ca_cert\n$ch_ca_cert" );

	# Run credhub api command
	my ( $api_out, $api_rc ) = run("credhub api \"$ch_url\" --ca-cert \"$ca_file\"");
	bail("Failed to target credhub API: $api_out") if $api_rc;

	# Login to credhub
	my ( $login_out, $login_rc ) = run("credhub login -u \"$ch_user\" -p \"$ch_pw\"");
	bail("Failed to login to credhub: $login_out") if $login_rc;

	# Display credhub version
	my ( $version_out, $version_rc ) = run("credhub --version");
	info("\n$version_out");

	return $self->done();
}

1;    # Required to end Perl modules

# vim: set ts=2 sw=2 sts=2 noet:
