#!/usr/bin/env perl
package Genesis::Hook::Addon::BOSH::DirectorCloudConfig v3.1.0;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);

# Give us the bosh and credhub functions that target this director instead of
# parent director
require File::Basename; require Cwd;
require(File::Basename::dirname(Cwd::abs_path(__FILE__)).'/lib/BoshDirectorAccess.pm');
BoshDirectorAccess->import();

use Genesis qw/info output/;
use Genesis::Term qw/terminal_width render_markdown decolorize/;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
	return $obj;
}

sub cmd_details {
	return
		"Generate and upload the cloud config for this director, which specifies ".
		"the azs and the complilation config, including its network, vm type, etc.".
		"\n".
		"Options:\n".
		"[[  #y{-n}      >>Dry run, just print out the director cloud config ".
		                  "without uploading it.\n".
		"[[  #y{-y}      >>Upload changes without prompting for confirmation.\n".
		"[[  #y{-R}      >>Remove the director cloud config from the director ".
		                  "instead.\n";
}

sub perform {
	my $self = shift;
	my $env = $self->env;

	# Parse options;
	my %opts = $self->parse_options([
		'dry-run|n',
		'compare|c',
		'yes|y',
		'remove|R',
	]);

	my $results = $env->run_hook('cloud-config', purpose => 'director');

	if ($opts{'dry-run'}) {
		info "Would have uploaded the following cloud config:";
		output $results->{'config'} =~ s/\s*\Z//mgr;

		#TODO: show the network allocation summary in $results->{'networks'}
		return 1;
	}

	# TODO: Upload the cloud config to the director
	
	# Next, if successful, update the network allocation in the environment
	# (this will be moved to a helper function: $env->update_network($results->{'network'}))
	my $path = $env->exodus_base . '/network';
	$env->vault->set_path($path, $results->{'network'}, flatten => 1);
	my $out = $env->exodus_lookup('/network');
	use Pry; pry;

	my $cc = $env->run_hook('cloud-config');

	use Pry; pry;

	# TODO... implement the rest
	
}

1
