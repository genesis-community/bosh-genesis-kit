#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 et:
package Genesis::Hook::Addon::BOSH::Resurrection v3.3.0; # ...::[KIT] v[KIT_VERSION]

use strict;
use warnings;
use v5.20; # Genesis supports min perl v5.20.

# Parent class inheritance
use parent qw(Genesis::Hook::Addon);

# Import required functions
use Genesis qw/bail error info warning trace debug describe lookup exit_status/;
use Genesis::Term qw/in_controlling_terminal/;

sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
	$obj->{files} = [];
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
  return $obj;
}

# Documentation that is shown when running with --help
sub cmd_details {
  return
  "Checks or sets bosh resurrection state. Set state with truthy or falsey\n".
  "arguments (ie: yes|no, true|false, on|off, enabled|disabled)\n".
  "\n".
  "With no argument, displays state if BOSH director is tracking\n".
  "the state; otherwise, reports state at last deployment.\n".
  "\n".
  "Note: This currently does not reflect resurrection config effects.\n".
  "\n".
  "Limitation: Database access is limited to internal PostgreSQL database.\n".
  "External PostgreSQL and MySQL may be supported in the future (PRs welcome)";
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;
  my $args = $self->{args} || [];

  # Process the command line arguments
  if (@$args) {
    my $state;

    # Parse state argument
    my $arg = $args->[0];
    if ($arg =~ /^(1|y|yes|t|true|on|enable.*)$/i) {
      $state = "on";
    } elsif ($arg =~ /^(0|n|no|f|false|off|disable.*)$/i) {
      $state = "off";
    } else {
      bail("", "#R{[ERROR]} Expecting one of the following arguments: on (aka: yes|true|enabled|1) or off (aka: no|false|disabled|0)");
    }

    # Update resurrection state
    my ($out, $rc, $err) = $env->bosh->execute("-A", "update-resurrection", $state);
    bail("Failed to set resurrection state: %s", $err) if $rc;
    info("");
    return 1;
  }

  # Get BOSH director IP
  my $ip = lookup("params.static_ip");
  describe("Target BOSH director located at $ip");

  # Determine if the environment has netop user active
  my $features = eval { lookup("--exodus", "features") } || "";
  my $has_netop = ($features !~ /\b(,|^)skip-ops-users(,|$)\b/);

  my @ssh_cmd;
  my $key_file;

  if ($has_netop) {
    # Set up SSH with netop user
    $key_file = $env->workpath(".key");

    open my $key_fh, ">", $key_file or bail("Could not create temporary key file: %s", $!);
    chmod 0600, $key_file;

    my $private_key = $self->vault->get($env->secrets_base."op/net:private");
    print $key_fh $private_key;
    close $key_fh;

    chmod 0400, $key_file;

    @ssh_cmd = ("ssh", "netop\@$ip", "-o", "StrictHostKeyChecking=no", "-i", $key_file);

  } elsif ($env->use_create_env) {
    # If create-env and no netop user, we can't proceed
    bail("#R{[ERROR]} Cannot connect to %s using netop user -- skip-op-users feature is enabled", $env->name);
  } else {
    # Do it the slow way via BOSH SSH
    #my $call_with_env = $self->env->get_call_path_with_env();
    # TODO: can we use the above
    @ssh_cmd = ($ENV{GENESIS_CALL_BIN}, $ENV{GENESIS_ENV_REF}, "bosh", "ssh", "-c");
  }

  # Try to find PostgreSQL client and query resurrection state
  describe("Connecting to PostgreSQL database on BOSH director...");

  my $psql;
  my ($out, $rc) = run({ stderr => '/dev/null' }, \@ssh_cmd,
    'ps auwwx| grep "/packages/[^ ]*/bin/[p]ostgres" | grep "/var/[^ ]*/bin/postgres" | sed -e \'s#.*\\(/var/[^ ]*/bin\\)/postgres.*#\\1/psql#\'');

  $psql = $out if ($rc == 0 && $out =~ /\S/);
  $psql =~ s/\s+$// if $psql;

  my $paused;
  if ($psql) {
    describe("Retrieving current resurrection status from database...");
    ($out, $rc) = run({ stderr => '/dev/null' }, \@ssh_cmd,
      $psql.' -U vcap -h localhost bosh -t -c "select value from director_attributes where name=\'resurrection_paused\' limit 1" | grep \' \\(true\\|false\\)\' | sed -E \'s/.* (true|false).*/\\1/\'');

    $paused = $out if ($rc == 0 && $out =~ /^(true|false)$/);
    $paused =~ s/\s+$// if $paused;
  } else {
    describe(STDERR, "#Y{Warning:} Could not determine Postgres client on BOSH instance -- cannot access database; deferring to last manifest value");
    $paused = 'not-available';
  }

  # Clean up key file if we created one
  unlink $key_file if $key_file && -f $key_file;

  # Determine resurrection state
  my $state;
  if ($paused eq 'true') {
    $state = "#R{off}";
  } elsif ($paused eq 'false') {
    $state = "#G{on}";
  } else {
    if ($paused ne 'not-available') {
      describe("#Y{Warning:} Database did not contain resurrection status - checking manifest of last deployment");
    }

    my $deployed_state = lookup("--deployed", "instance_groups[name=bosh].properties.hm.resurrector_enabled");

    if ($deployed_state eq 'true') {
      $state = "#G{on} (based on last deployed manifest)";
    } elsif ($deployed_state eq 'false') {
      $state = "#R{off} (based on last deployed manifest)";
    } else {
      $state = "#Y{unknown}";
    }
  }

  # Output result
  describe("", "Resurrection on $ENV{GENESIS_ENVIRONMENT} is currently $state", "");

  return $self->done(1);
}

# Helper function to run commands and capture output
sub run {
  my ($options, $cmd, @args) = @_;

  my $cmd_str = join(" ", @$cmd, @args);
  debug("Running command: $cmd_str");

  my $stdout;
  my $stderr;
  open my $old_stdout, ">&", \*STDOUT or die "Can't dup STDOUT: $!";
  open my $old_stderr, ">&", \*STDERR or die "Can't dup STDERR: $!";

  open my $out, ">", \$stdout or die "Can't redirect STDOUT: $!";
  open STDOUT, ">&", $out or die "Can't redirect STDOUT: $!";

  unless ($options->{stderr} && $options->{stderr} eq '/dev/null') {
    open my $err, ">", \$stderr or die "Can't redirect STDERR: $!";
    open STDERR, ">&", $err or die "Can't redirect STDERR: $!";
  }

  system(@$cmd, @args);
  my $rc = $? >> 8;

  close $out;
  open STDOUT, ">&", $old_stdout or die "Can't restore STDOUT: $!";
  open STDERR, ">&", $old_stderr or die "Can't restore STDERR: $!";

  return (($stdout || ""), $rc);
}

1;
