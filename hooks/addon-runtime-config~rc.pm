#!/usr/bin/env perl
package Genesis::Hook::Addon::BOSH::RuntimeConfig v4.0.6;

use strict;
use warnings;

# Only needed for development
my $lib;
BEGIN {$lib = $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use lib $lib;

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info warning success pretty_duration run in_array compare_arrays read_json_from mkfile_or_fail count_nouns/;
use Genesis::UI qw/prompt_for_boolean/;
use Genesis::Term qw/wrap terminal_width render_markdown decolorize bullet/;
use Time::HiRes qw/gettimeofday/;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.20');

	# Define valid builds
	my $valid_builds = [qw/dns ops-access toolbelt syslog/];

	$obj->{args} //= [];
	my $opts = $obj->parse_options([
		'dry-run|n',
		'yes|y',
		'remove|R',
		'print|p',
		'stemcells=s', # comma separated list of stemcells
	]);
	for my $opt (keys %$opts) {
		my $key = $opt =~ s/-//rg;
		$obj->{$key} = $opts->{$opt};
	}

	my @args = ();
	if ($obj->{args}->@*) {
		(undef, my $builds, my $invalid_builds) = compare_arrays(
			$valid_builds, $obj->{args}
		);
		if (in_array(@$invalid_builds, 'all', '*')) {
			bail(
				"You cannot use 'all' or '*' with other runtime config names. ".
				"Please specify only one of them."
			) if (@$builds || @$invalid_builds > 1);
			$builds = 'all';
			$invalid_builds = [];
		}
		bail(
			"Invalid runtime config(s): %s - valid values are: %s (or 'all'/'*' to include all)",
			join(", ", @$invalid_builds),
			join(", ", @$valid_builds)
		) if (@$invalid_builds);
		@args = @$builds;
	} else {
		@args = ('all');
	}
	my $options = {};
	$options->{params}{stemcells} = [split(',', $opts->{stemcells})] if ($opts->{stemcells});
	$obj->{args} = [map {($_ => $options)} @args];
	return $obj;
}

sub cmd_details {
	return
		"runtime-config [--dry-run] [--yes] [--remove] [<runtime-config> ... ]\n".
		"\n".
		"Generate and upload runtime config(s) to the target BOSH director.\n".
		"\n".
		"Options:\n".
		"[[  #y{-n}         >>Dry run, just print out the runtime config without ".
		                     "uploading it.\n".
		"[[  #y{-y}         >>Upload changes without prompting for confirmation.\n".
		"[[  #y{-R}         >>Remove the runtime config from the director instead.\n".
		"[[  #y{-p}         >>Print the runtime config to stdout instead of uploading it.\n".
		"[[  #y{stemcells}  >>Specify stemcells to use for the selected configs (comma separated list).\n".
		"\n".
		"Runtime Configs:\n".
		"[[  #B{dns}        >>Generate, upload and/or remove the BOSH DNS runtime config.\n".
		"[[  #B{ops-access} >>Generate, upload and/or remove the Ops Access runtime config.\n".
		"[[  #B{toolbelt}   >>Generate, upload and/or remove the Toolbelt runtime config.\n".
		"[[  #B{syslog}     >>Generate, upload and/or remove the Syslog runtime config.\n".
		"\n".
		"By default, all of the above runtime configs are generated and uploaded, or removed.\n"
}

sub perform {
	my $self = shift;
	my $env = $self->env;

	return $self->done(
		$self->env->run_hook('runtime-config',
			env => $env,
			args => $self->{args},
			dryrun => $self->{dryrun},
			interactive => !$self->{yes},
			remove => $self->{remove},
			print => $self->{print},
		)
	);
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
