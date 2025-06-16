#!/usr/bin/env perl

package Genesis::Hook::Addon::Bosh v3.0.4; # ...::[KIT] v[KIT_VERSION]

use strict;
use warnings;
use v5.20;

BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info warning error in_array new_enough/;

sub init {
  my ($class, %ops) = @_;
  my $self = $class->SUPER::init(%ops);

  $self->check_minimum_genesis_version('3.1.0-rc.9');

  # Clear BOSH environment variables as done in the bash script
  delete $ENV{BOSH_ENVIRONMENT};
  delete $ENV{BOSH_CA_CERT};
  delete $ENV{BOSH_CLIENT};
  delete $ENV{BOSH_CLIENT_SECRET};

  # Set BOSH_URL for our use (as done in bash script)
  $ENV{BOSH_URL} = "https://" . $self->env->lookup('params.static_ip') . ":25555";

  return $self;
}

sub cmd_details {
  return "Manage BOSH director operations for this environment.\n\n" .
  "Available commands:\n" .
  "  alias  - Set up a local bosh alias for a director\n" .
  "  login  - Log into an (aliased) director\n" .
  "  logout - Log out of an (aliased) director";
}

sub perform {
  my ($self) = @_;

  my $script = $self->{script};

  if ($script eq 'list') {
    # List available addons
    return $self->list_addons();
  }
  elsif ($script eq 'alias') {
    return $self->setup_alias();
  }
  elsif ($script eq 'login') {
    $self->has_alias() || $self->setup_alias(1);
    return $self->login();
  }
  elsif ($script eq 'logout') {
    $self->has_alias() || $self->setup_alias(1);
    return $self->logout();
  }
  elsif ($script eq 'ssh') {
    return $self->ssh_to_director();
  }
  else {
    # Try running it as an extended addon
    return $self->run_extended_addon();
  }
}

sub list_addons {
  my ($self) = @_;

  # This maps to print_addon_descriptions in the bash script
  info(
    "alias  - Set up a local bosh alias for a director\n" .
    "login  - Log into an (aliased) director\n" .
    "logout - Log out of an (aliased) director"
  );

  return 1;
}

sub setup_alias {
  my ($self, $silent) = @_;

  my $env_name = $ENV{GENESIS_ENVIRONMENT};

  if ($silent) {
    run(
      { stdout => '/dev/null' },
      'bosh -A alias-env --tty "$1"',
      $env_name
    );
  } else {
    my ($output, $rc, $stderr) = run('bosh -A alias-env --tty "$1"', $env_name);
    $output =~ s/^User.*$//m; # Remove User line as done in bash
    info($output);
  }

  return 1;
}

sub has_alias {
  my ($self) = @_;

  my $env_name = $ENV{GENESIS_ENVIRONMENT};
  my ($output) = run('bosh envs | grep http | awk \'{print $2}\'');

  my @aliases = split(/\n/, $output);
  return grep { $_ eq $env_name } @aliases;
}

sub is_logged_in {
  my ($self) = @_;

  my $env_name = $ENV{GENESIS_ENVIRONMENT};
  my ($user) = run('bosh -e "$1" env --json | jq -Mr ".Tables[0].Rows[0].user"', $env_name);

  chomp($user);

  if ($user eq 'null' || $user eq '(not logged in)') {
    return 0;
  }

  if ($user ne 'admin') {
    describe("Logged in as #C{$user}, expected to be #C{admin}");
    return 0;
  }

  describe("Logged in as #C{$user}...");
  return 1;
}

sub login {
  my ($self) = @_;

  my $env_name = $ENV{GENESIS_ENVIRONMENT};
  my $admin_password = $self->vault->get($ENV{GENESIS_SECRETS_BASE} . "users/admin", "password");

  info("Logging you in as user 'admin'...");

  # Create a temporary file with login credentials
  my $login_file = workdir() . "/.bosh_login";
  mkfile_or_fail($login_file, 0600, "admin\n$admin_password\n");

  # Execute login command
  my ($output, $rc, $stderr) = run('cat "$1" | bosh -e "$2" login', $login_file, $env_name);

  # Clean up
  unlink $login_file;

  if ($rc != 0) {
    error("Failed to log in: $stderr");
    return 0;
  }

  return 1;
}

sub logout {
  my ($self) = @_;

  my $env_name = $ENV{GENESIS_ENVIRONMENT};
  run('bosh -e "$1" logout', $env_name);

  return 1;
}

sub ssh_to_director {
  my ($self) = @_;

  info("\n#G{Accessing $ENV{GENESIS_ENVIRONMENT} BOSH director via SSH...}\n");

  # Create temporary key file
  my $key_file = workdir() . "/.ssh_key";
  mkfile_or_fail($key_file, 0600, "");

  # Get private key from vault
  my $private_key = $self->vault->get($ENV{GENESIS_SECRETS_BASE} . "op/net", "private");
  mkfile_or_fail($key_file, 0400, $private_key);

  # Get director host or IP address
	my $ip = $self->_get_host_address();

  # Set up cleanup
  local $SIG{INT} = local $SIG{TERM} = local $SIG{QUIT} = sub {
    unlink $key_file;
    exit 1;
  };

  # Execute SSH command
  delete $ENV{SSH_AUTH_SOCK};
  system("ssh", "netop\@$ip", "-o", "StrictHostKeyChecking=no", "-i", $key_file);

  # Clean up
  unlink $key_file;

  return 1;
}

# Helper method to delegate to an extended addon
sub run_extended_addon {
  my ($self) = @_;

  # In the original bash script, this would delegate to another addon script
  # For now, we'll just report that the addon wasn't found
  bail("Unknown addon script: $self->{script}");
}

sub _get_host_address {
	my ($self) = @_;
	my $bosh = $self->env->get_target_bosh({self => 1});
	return $bosh->{host} if $bosh && $bosh->{host};
	bail("No BOSH host address found for environment: " . $self->env->name);
}

1;
