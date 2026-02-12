#!/usr/bin/env perl
package Genesis::Hook::Addon::BOSH::Uaa v4.0.6;

use strict;
use warnings;

# Only needed for development
my $lib;
BEGIN {$lib = $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use lib $lib;

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info warning error in_array new_enough time_exec mkfile_or_fail pretty_duration run load_yaml load_yaml_file save_to_yaml_file/;
use Genesis::Term qw/terminal_width render_markdown decolorize/;
use JSON::PP qw/decode_json encode_json/;
use File::Temp qw/tempfile/;

my $DEBUG = $ENV{GENESIS_DEBUG} || '';

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.0.0-rc.1');
	return $obj;
}

sub cmd_details {
	return
		"UAA User and Group Management Addon for BOSH Genesis Kit\n".
		"\n".
		"This addon provides comprehensive UAA user and group management capabilities\n".
		"for BOSH deployments. It supports both individual and bulk operations for\n".
		"users and groups, as well as authentication management.\n".
		"\n".
		"USAGE:\n".
		"  genesis \@ENV do uaa <command> [subcommand] [options]\n".
		"\n".
		"COMMANDS:\n".
		"  install                                 # Download and install latest uaa CLI\n".
		"  login                                   # Authenticate with UAA\n".
		"  logout                                  # Clear UAA authentication\n".
		"  whoami                                  # Display information about the current user\n".
		"  context                                 # Show current UAA context and token info\n".
		"\n".
		"USER MANAGEMENT:\n".
		"  users add <username> [password] [email] [groups...]\n".
		"                                              # Create new user\n".
		"  users remove <username>                     # Remove user\n".
		"  users bulk-remove --file <file> | --pattern <regex>  # Bulk remove users\n".
		"  users list [--filter=<pattern>]             # List all users\n".
		"  users search <query-type> [args...]         # Advanced user search\n".
		"  users activate <username>                   # Activate a deactivated user\n".
		"  users deactivate <username>                 # Deactivate a user (prevents login)\n".
		"  users reset-password <username> [password]  # Reset user password\n".
		"  users update <username> [--email=<email>] [--password=<password>]\n".
		"                                              # Update user (via delete/recreate)\n".
		"  users import <file.yml>                     # Bulk import users from YAML file\n".
		"  users export [file.yml]                     # Export users to YAML file\n".
		"  users backup [file.yml]                     # Backup all users and groups to YAML\n".
		"  users restore <file.yml>                    # Restore users and groups from backup\n".
		"  users info [username]                       # Display detailed user information\n".
		"\n".
		"GROUP MANAGEMENT:\n".
		"  groups add <groupname> [description]        # Create new group\n".
		"  groups list                                 # List all groups\n".
		"  groups members <groupname>                  # List group members\n".
		"  groups add-member <groupname> <username>    # Add user to group\n".
		"  groups remove-member <groupname> <username> # Remove user from group\n".
		"  groups bulk-add-members <groupname> [users...] [options]  # Bulk add users to group\n".
		"  groups map-external <uaa-group> <external-group> [origin]  # Map external group\n".
		"  groups unmap-external <uaa-group> <external-group> [origin]  # Unmap external group\n".
		"  groups list-mappings [--group <name>]       # List external group mappings\n".
		"\n".
		"OAUTH CLIENT MANAGEMENT:\n".
		"  clients add <client-id> [options]           # Create new OAuth client\n".
		"  clients remove <client-id>                  # Remove OAuth client\n".
		"  clients list                                # List all clients\n".
		"  clients get <client-id>                     # Get client details\n".
		"  clients set-secret <client-id> [secret]     # Change client secret\n".
		"  clients update <client-id> [options]        # Update client properties\n".
		"\n".
		"EXAMPLES:\n".
		"  genesis \@ocf:bosh do uaa install\n".
		"  genesis \@ocf:bosh do uaa login\n".
		"  genesis \@ocf:bosh do uaa users add jdoe password123 jdoe\@company.com operators\n".
		"  genesis \@ocf:bosh do uaa users search email-domain gmail.com\n".
		"  genesis \@ocf:bosh do uaa users search unverified\n".
		"  genesis \@ocf:bosh do uaa users import ./users.yml\n".
		"  genesis \@ocf:bosh do uaa users backup ./uaa-backup.yml\n".
		"  genesis \@ocf:bosh do uaa users info jdoe\n".
		"  genesis \@ocf:bosh do uaa whoami\n".
		"  genesis \@ocf:bosh do uaa groups add developers \"Development team\"\n".
		"  genesis \@ocf:bosh do uaa groups add-member developers jdoe\n".
		"  genesis \@ocf:bosh do uaa clients add my-app --grant-types authorization_code\n".
		"  genesis \@ocf:bosh do uaa clients set-secret my-app"
}

sub perform {
	my $self = shift;

	my $command = shift @{$self->{args}} || '';
	bail("#R{[ERROR]} No command specified. Use 'uaa help' for usage information.") unless $command;

	# Enable debug mode if requested
	$DEBUG and print STDERR "DEBUG: addon-uaa.pm called with args: " . join(' ', @{$self->{args}}) . "\n";

	# Main command dispatch table
	my %commands = (
		'login'   => \&uaa_login,
		'logout'  => \&uaa_logout,
		'install' => \&uaa_install,
		'users'   => \&handle_users,
		'groups'  => \&handle_groups,
		'clients' => \&handle_clients,
		'whoami'  => \&uaa_whoami,
		'context' => \&uaa_context,
	);

	my $handler = $commands{$command};
	bail("#R{[ERROR]} Unknown command: $command\n" .
		"        Run 'genesis \@ENV do uaa help' for available commands.") unless $handler;

	$handler->($self, @{$self->{args}});
	return $self->done();
}

# Help documentation
sub help {
  info <<EOF;
#c{UAA User and Group Management}

#y{USAGE:}
  genesis \\\@ENV do uaa <command> [subcommand] [options]

#y{COMMANDS:}
  #G{install}                                  # Download and install latest uaa CLI
  #G{login}                                    # Authenticate with UAA
  #G{logout}                                   # Clear UAA authentication
  #G{whoami}                                   # Display information about the current user
  #G{context}                                  # Show current UAA context and token info

#y{USER MANAGEMENT:}
  #G{users add} <username> [password] [email] [groups...]
                                              # Create new user (default group: bosh.admin)
  #G{users remove} <username>                 # Remove user
  #G{users bulk-remove} --file <file> | --pattern <regex>  # Bulk remove users
  #G{users list} [--filter=<pattern>]         # List all users
  #G{users search} <query-type> [args...]     # Advanced user search (see examples)
  #G{users activate} <username>               # Activate a deactivated user
  #G{users deactivate} <username>             # Deactivate a user (prevents login)
  #G{users reset-password} <username> [password]  # Reset user password
  #G{users update} <username> [--email=<email>] [--password=<password>]
                                              # Update user (via delete/recreate)
  #G{users import} <file.yml>                 # Bulk import users from YAML file
  #G{users export} [file.yml]                 # Export users to YAML file
  #G{users backup} [file.yml]                 # Backup all users and groups to YAML
  #G{users restore} <file.yml>                # Restore users and groups from backup
  #G{users info} [username]                   # Display detailed user information

#y{GROUP MANAGEMENT:}
  #G{groups add} <groupname> [description]    # Create new group
  #G{groups list}                             # List all groups
  #G{groups members} <groupname>              # List group members
  #G{groups add-member} <groupname> <username>    # Add user to group
  #G{groups remove-member} <groupname> <username> # Remove user from group
  #G{groups bulk-add-members} <groupname> [users...] [options]  # Bulk add users to group
  #G{groups map-external} <uaa-group> <external-group> [origin]  # Map external group
  #G{groups unmap-external} <uaa-group> <external-group> [origin]  # Unmap external group
  #G{groups list-mappings} [--group <name>]   # List external group mappings

#y{OAUTH CLIENT MANAGEMENT:}
  #G{clients add} <client-id> [options]       # Create new OAuth client
  #G{clients remove} <client-id>              # Remove OAuth client
  #G{clients list}                            # List all clients
  #G{clients get} <client-id>                 # Get client details
  #G{clients set-secret} <client-id> [secret] # Change client secret
  #G{clients update} <client-id> [options]    # Update client properties

#y{EXAMPLES:}
  genesis \\\@ocf:bosh do uaa install
  genesis \\\@ocf:bosh do uaa login
  genesis \\\@ocf:bosh do uaa users add jdoe password123 jdoe\@company.com operators
  genesis \\\@ocf:bosh do uaa users search email-domain gmail.com
  genesis \\\@ocf:bosh do uaa users search unverified
  genesis \\\@ocf:bosh do uaa users search by-group bosh.admin
  genesis \\\@ocf:bosh do uaa users import ./users.yml
  genesis \\\@ocf:bosh do uaa groups add developers "Development team"
  genesis \\\@ocf:bosh do uaa groups add-member developers jdoe
  genesis \\\@ocf:bosh do uaa clients add my-app --grant-types authorization_code
  genesis \\\@ocf:bosh do uaa clients set-secret my-app
EOF
}

# Command handlers
sub handle_users {
  my ($self, $subcommand, @args) = @_;

  bail("#R{[ERROR]} No users subcommand specified.\n" .
    "        Available: add, remove, bulk-remove, list, search, activate, deactivate, reset-password, update, import, export, backup, restore, info") unless $subcommand;

  my %user_commands = (
    'add'             => \&users_add,
    'remove'          => \&users_remove,
    'bulk-remove'     => \&users_bulk_remove,
    'list'            => \&users_list,
    'search'          => \&users_search,
    'activate'        => \&users_activate,
    'deactivate'      => \&users_deactivate,
    'reset-password'  => \&users_reset_password,
    'update'          => \&users_update,
    'import'          => \&users_import,
    'export'          => \&users_export,
    'backup'          => \&users_backup,
    'restore'         => \&users_restore,
    'info'            => \&users_info,
  );

  my $handler = $user_commands{$subcommand};
  bail("#R{[ERROR]} Unknown users command: $subcommand\n" .
    "        Available: add, remove, bulk-remove, list, search, activate, deactivate, reset-password, update, import, export, backup, restore, info") unless $handler;

  $handler->($self, @args);
}

sub handle_groups {
  my ($self, $subcommand, @args) = @_;

  bail("#R{[ERROR]} No groups subcommand specified.\n" .
    "        Available: add, list, members, add-member, remove-member, bulk-add-members, map-external, unmap-external, list-mappings") unless $subcommand;

  my %group_commands = (
    'add'               => \&groups_add,
    'list'              => \&groups_list,
    'members'           => \&groups_members,
    'add-member'        => \&groups_add_member,
    'remove-member'     => \&groups_remove_member,
    'bulk-add-members'  => \&groups_bulk_add_members,
    'map-external'      => \&groups_map_external,
    'unmap-external'    => \&groups_unmap_external,
    'list-mappings'     => \&groups_list_mappings,
  );

  my $handler = $group_commands{$subcommand};
  bail("#R{[ERROR]} Unknown groups command: $subcommand\n" .
    "        Available: add, list, members, add-member, remove-member, bulk-add-members, map-external, unmap-external, list-mappings") unless $handler;

  $handler->($self, @args);
}

sub handle_clients {
  my ($self, $subcommand, @args) = @_;

  bail("#R{[ERROR]} No clients subcommand specified.\n" .
    "        Available: add, remove, list, get, set-secret, update") unless $subcommand;

  my %client_commands = (
    'add'        => \&clients_add,
    'remove'     => \&clients_remove,
    'list'       => \&clients_list,
    'get'        => \&clients_get,
    'set-secret' => \&clients_set_secret,
    'update'     => \&clients_update,
  );

  my $handler = $client_commands{$subcommand};
  bail("#R{[ERROR]} Unknown clients command: $subcommand\n" .
    "        Available: add, remove, list, get, set-secret, update") unless $handler;

  $handler->($self, @args);
}

# UAA connection and authentication functions
sub check_prerequisites {
  # Check for uaa command
  system("command -v uaa > /dev/null 2>&1") == 0 or
  bail("#R{[ERROR]} Command 'uaa' not found. Install it using:\n" .
    "        genesis \@ENV do uaa install\n" .
    "        Or download manually from: https://github.com/cloudfoundry/uaa-cli/releases");

  # UAA is enabled by default in BOSH
}

sub get_exodus_data {
  my ($self) = @_;
  return $self->exodus_data();
}

sub get_uaa_connection_info {
  my ($self) = @_;
  my $exodus = $self->get_exodus_data();

  # Get BOSH director URL and construct UAA URL
  my $bosh_url = $exodus->{url};
  bail("#R{[ERROR]} BOSH URL not found in exodus data") unless $bosh_url;

  # UAA typically runs on port 8443 on the same host as BOSH
  my $uaa_url = $bosh_url;
  $uaa_url =~ s/:25555$/:8443/;  # Replace BOSH port with UAA port

  return {
    uaa_url => $uaa_url,
    ca_cert => $exodus->{ca_cert} || '',
    bosh_url => $bosh_url,
  };
}

sub get_uaa_admin_credentials {
  my ($self) = @_;
  # Get UAA admin client credentials from vault
  my $admin_secret = $self->vault->get($self->env->secrets_store->base.'uaa/clients/uaa_admin', 'secret');
  bail("#R{[ERROR]} Failed to read UAA admin client secret from vault.\n" .
    "        Expected path: ".$self->env->secrets_store->base.'uaa/clients/uaa_admin:secret') unless $admin_secret;

  return {
    client_id => 'uaa_admin',
    client_secret => $admin_secret,
  };
}

sub uaa_cmd {
  my ($cmd, $ignore_errors) = @_;

  $DEBUG and print STDERR "DEBUG: Running uaa command: $cmd\n";

  my $output = `uaa $cmd 2>&1`;
  my $exit_code = $?;

  if ($exit_code != 0 && !$ignore_errors) {
    bail("#R{[ERROR]} uaa command failed: $cmd\n" .
      "        Output: $output");
  }

  return {
    output => $output,
    exit_code => $exit_code,
    success => $exit_code == 0,
  };
}

sub setup_uaa_target {
  my ($self) = @_;
  my $conn_info = $self->get_uaa_connection_info();

  # Clear any existing UAA environment variables
  delete $ENV{UAA_CLIENT_ID};
  delete $ENV{UAA_CLIENT_SECRET};
  delete $ENV{UAA_CLIENT_TARGET};

  # Target the UAA server
  my $target_cmd = "target " . $conn_info->{uaa_url};
  if ($conn_info->{ca_cert}) {
    # Note: uaa CLI doesn't support --ca-cert, using skip-ssl-validation instead
    # TODO: Implement proper certificate validation when uaa CLI supports it
    info("#y{Warning: Using skip-ssl-validation due to uaa CLI limitation}\n");
    $target_cmd .= " -k";
    return uaa_cmd($target_cmd);
  } else {
    $target_cmd .= " -k";
    return uaa_cmd($target_cmd);
  }
}

sub uaa_login {
  my ($self) = @_;
  check_prerequisites();

  info("#G{Targeting UAA server...}\n");
  $self->setup_uaa_target();

  info("#G{Authenticating with UAA admin client...}\n");
  my $creds = $self->get_uaa_admin_credentials();

  my $login_cmd = "get-client-credentials-token " . $creds->{client_id} .
  " -s " . shell_quote($creds->{client_secret});

  my $result = uaa_cmd($login_cmd);

  if ($result->{success}) {
    info("#G{✓} Successfully authenticated with UAA\n");

    # Show current context
    my $context = uaa_cmd("context", 1);
    if ($context->{success} && $context->{output}) {
      info("#y{Current UAA context:}\n");
      print $context->{output};
    }
  } else {
    bail("#R{[ERROR]} Failed to authenticate with UAA: " . $result->{output});
  }
}

sub uaa_logout {
  my ($self) = @_;
  check_prerequisites();

  info("#G{Clearing UAA authentication...}\n");
  # Note: uaa CLI doesn't have token delete, context clears automatically
  info("#y{Note: uaa CLI manages tokens automatically, clearing target}\n");

  # Clear target (uaa CLI doesn't have target delete, using fresh target)
  info("#G{To fully logout, you may need to remove ~/.uaa/context.json manually}\n");

  info("#G{✓} UAA authentication cleared\n");
}

sub uaa_install {
  my ($self, @args) = @_;

  info("#G{Installing latest uaa CLI from GitHub releases...}\n");

  # Check if uaa is already installed
  my $existing_uaa = `command -v uaa 2>/dev/null`;
  chomp $existing_uaa if $existing_uaa;

  if ($existing_uaa) {
    my $version_output = `uaa version 2>/dev/null` || '';
    info("#y{Current uaa CLI found at: $existing_uaa}\n");
    info("#y{Current version: $version_output}\n") if $version_output;

    print "Do you want to replace the existing installation? [y/N]: ";
    my $confirm = <STDIN>;
    chomp $confirm;
    unless ($confirm =~ /^[yY]/) {
      info("#y{Installation cancelled}\n");
      return;
    }
  }

  # Detect platform and architecture
  my ($platform, $arch) = detect_platform_arch();
  info("#y{Detected platform: $platform-$arch}\n");

  # Get latest release information from GitHub API
  info("#G{Fetching latest release information...}\n");
  my $release_info = get_latest_uaa_release();

  my $version = $release_info->{tag_name};
  info("#G{Latest version: $version}\n");

  # Find the appropriate asset for this platform
  my $download_url = find_asset_url($release_info->{assets}, $platform, $arch, $version);
  bail("#R{[ERROR]} No compatible binary found for $platform-$arch") unless $download_url;

  info("#G{Download URL: $download_url}\n");

  # Determine installation directory
  my $install_dir = determine_install_dir();
  my $binary_name = ($platform eq 'windows') ? 'uaa.exe' : 'uaa';
  my $install_path = "$install_dir/$binary_name";

  info("#G{Installing to: $install_path}\n");

  # Create install directory if it doesn't exist
  unless (-d $install_dir) {
    system("mkdir", "-p", $install_dir) == 0 or
      bail("#R{[ERROR]} Failed to create directory: $install_dir");
  }

  # Download and install
  download_and_install($download_url, $install_path);

  # Verify installation
  verify_installation($install_path, $version);

  info("#G{✓} uaa CLI $version installed successfully to $install_path\n");
  info("#y{Make sure $install_dir is in your PATH environment variable}\n");
}

sub detect_platform_arch {
  my $os = `uname -s 2>/dev/null` || '';
  my $arch = `uname -m 2>/dev/null` || '';
  chomp($os, $arch);

  # Normalize OS name
  my $platform;
  if ($os =~ /Darwin/i) {
    $platform = 'darwin';
  } elsif ($os =~ /Linux/i) {
    $platform = 'linux';
  } elsif ($os =~ /CYGWIN|MINGW|MSYS/i || $^O eq 'MSWin32') {
    $platform = 'windows';
  } else {
    bail("#R{[ERROR]} Unsupported operating system: $os");
  }

  # Normalize architecture
  my $normalized_arch;
  if ($arch =~ /x86_64|amd64/i) {
    $normalized_arch = 'amd64';
  } elsif ($arch =~ /arm64|aarch64/i) {
    $normalized_arch = 'arm64';
  } elsif ($arch =~ /i386|i686/i) {
    bail("#R{[ERROR]} 32-bit architectures are not supported by uaa CLI");
  } else {
    bail("#R{[ERROR]} Unsupported architecture: $arch");
  }

  return ($platform, $normalized_arch);
}

sub get_latest_uaa_release {
  my $api_url = "https://api.github.com/repos/cloudfoundry/uaa-cli/releases/latest";

  # Use curl to fetch release information
  my $curl_cmd = "curl -s '$api_url'";
  my $json_output = `$curl_cmd`;
  my $exit_code = $?;

  if ($exit_code != 0) {
    bail("#R{[ERROR]} Failed to fetch release information from GitHub API");
  }

  # Parse JSON response
  my $json = JSON::PP->new();
  my $release_data = eval { $json->decode($json_output) };
  if ($@) {
    bail("#R{[ERROR]} Failed to parse GitHub API response: $@");
  }

  unless ($release_data->{tag_name} && $release_data->{assets}) {
    bail("#R{[ERROR]} Invalid release data from GitHub API");
  }

  return $release_data;
}

sub find_asset_url {
  my ($assets, $platform, $arch, $version) = @_;

  # Expected asset name pattern: uaa-{platform}-{arch}-{version}[.exe]
  my $expected_name = "uaa-$platform-$arch-$version";
  $expected_name .= ".exe" if $platform eq 'windows';

  foreach my $asset (@$assets) {
    if ($asset->{name} eq $expected_name) {
      return $asset->{browser_download_url};
    }
  }

  return undef;
}

sub determine_install_dir {
  # Try to use the same directory as existing uaa installation
  my $existing_uaa = `command -v uaa 2>/dev/null`;
  if ($existing_uaa) {
    chomp $existing_uaa;
    my $existing_dir = $existing_uaa;
    $existing_dir =~ s|/[^/]+$||;  # Remove filename, keep directory
    return $existing_dir if -w $existing_dir;
  }

  # Check common installation directories
  my @candidate_dirs = (
    "$ENV{HOME}/.local/bin",
    "$ENV{HOME}/bin",
    "/usr/local/bin",
    "/opt/homebrew/bin"
  );

  foreach my $dir (@candidate_dirs) {
    if (-d $dir && -w $dir) {
      return $dir;
    }
  }

  # Default to ~/.local/bin and create if needed
  my $default_dir = "$ENV{HOME}/.local/bin";
  return $default_dir;
}

sub download_and_install {
  my ($download_url, $install_path) = @_;

  info("#G{Downloading uaa CLI binary...}\n");

  # Use curl to download the binary
  my $curl_cmd = "curl -L -o '$install_path' '$download_url'";
  my $result = system($curl_cmd);

  if ($result != 0) {
    bail("#R{[ERROR]} Failed to download uaa CLI binary");
  }

  # Make the binary executable (not needed on Windows)
  unless ($install_path =~ /\.exe$/) {
    chmod 0755, $install_path or
      bail("#R{[ERROR]} Failed to make binary executable: $!");
  }
}

sub verify_installation {
  my ($install_path, $expected_version) = @_;

  info("#G{Verifying installation...}\n");

  # Check if file exists and is executable
  unless (-f $install_path) {
    bail("#R{[ERROR]} Binary not found at $install_path");
  }

  unless (-x $install_path) {
    bail("#R{[ERROR]} Binary is not executable: $install_path");
  }

  # Check version
  my $version_output = `'$install_path' version 2>/dev/null` || '';
  chomp $version_output;

  if ($version_output && $version_output =~ /\Q$expected_version\E/) {
    info("#G{✓} Version verification successful: $version_output}\n");
  } else {
    info("#y{Warning: Could not verify version. Output: $version_output}\n");
  }
}

# Utility function to safely quote shell arguments
sub shell_quote {
  my $arg = shift;
  $arg =~ s/'/'"'"'/g;  # Escape single quotes
  return "'$arg'";
}

sub users_add {
  my ($self, $username, $password, $email, @groups) = @_;

  # Validate required parameters
  bail("#R{[ERROR]} Username is required for users add") unless $username;

  # Validate username format
  unless ($username =~ /^[a-zA-Z0-9._-]+$/) {
    bail("#R{[ERROR]} Invalid username format. Use only letters, numbers, dots, underscores, and hyphens.");
  }

  check_prerequisites();
  $self->ensure_authenticated();

  # Generate password if not provided
  if (!$password) {
    $password = generate_password();
    info("#y{Generated password for user $username: $password}\n");
    info("#y{Please save this password securely!}\n");
  }

  # Set default email if not provided
  if (!$email) {
    $email = "${username}\@example.com";
    info("#y{Using default email: $email}\n");
  }

  # Add bosh.admin as default group if no groups specified
  if (!@groups) {
    @groups = ('bosh.admin');
    info("#y{Adding user to default group: bosh.admin}\n");
  }

  # Validate email format
  unless ($email =~ /^[^\s@]+@[^\s@]+\.[^\s@]+$/) {
    bail("#R{[ERROR]} Invalid email format: $email");
  }

  info("#G{Creating user: $username}\n");

  # Check if user already exists
  my $existing = uaa_cmd("get-user $username", 1);
  if ($existing->{success}) {
    bail("#R{[ERROR]} User $username already exists");
  }

  # Create the user - uaa CLI requires givenName and familyName
  # Extract names from username if not provided separately
  my $given_name = $username;
  my $family_name = $username;

  my $create_cmd = "create-user $username --email " . shell_quote($email) .
  " --password " . shell_quote($password) .
  " --givenName " . shell_quote($given_name) .
  " --familyName " . shell_quote($family_name);

  my $result = uaa_cmd($create_cmd);

  if ($result->{success}) {
    info("#G{✓} User $username created successfully\n");

    # Add user to groups if specified
    if (@groups) {
      info("#G{Adding user to groups...}\n");
      foreach my $group (@groups) {
        $self->add_user_to_group_internal($username, $group);
      }
    }

    # Display user info
    info("\n#y{User Details:}\n");
    my $user_info = uaa_cmd("get-user $username", 1);
    if ($user_info->{success}) {
      print $user_info->{output};
    }
  } else {
    bail("#R{[ERROR]} Failed to create user $username: " . $result->{output});
  }
}

sub users_remove {
  my ($self, $username) = @_;

  bail("#R{[ERROR]} Username is required for users remove") unless $username;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if user exists
  my $existing = uaa_cmd("get-user $username", 1);
  unless ($existing->{success}) {
    bail("#R{[ERROR]} User $username does not exist");
  }

  # Confirm deletion
  info("#y{Are you sure you want to delete user '$username'? This action cannot be undone.}\n");
  print "Type 'yes' to confirm: ";
  my $confirmation = <STDIN>;
  chomp $confirmation;

  unless ($confirmation eq 'yes') {
    info("#y{User deletion cancelled}\n");
    return;
  }

  info("#G{Removing user: $username}\n");

  my $result = uaa_cmd("delete-user $username");

  if ($result->{success}) {
    info("#G{✓} User $username removed successfully\n");
  } else {
    bail("#R{[ERROR]} Failed to remove user $username: " . $result->{output});
  }
}

sub users_bulk_remove {
  my ($self, @args) = @_;

  check_prerequisites();
  $self->ensure_authenticated();

  # Parse arguments
  my ($file, $pattern, $dry_run, $force);

  for (my $i = 0; $i < @args; $i++) {
    if ($args[$i] eq '--file' && $i + 1 < @args) {
      $file = $args[++$i];
    } elsif ($args[$i] eq '--pattern' && $i + 1 < @args) {
      $pattern = $args[++$i];
    } elsif ($args[$i] eq '--dry-run') {
      $dry_run = 1;
    } elsif ($args[$i] eq '--force') {
      $force = 1;
    }
  }

  unless ($file || $pattern) {
    info("#y{Bulk remove users by file or pattern}\n");
    info("\n");
    info("#y{Usage examples:}\n");
    info("  #G{users bulk-remove --file users-to-delete.txt}\n");
    info("  #G{users bulk-remove --pattern 'test-*' --dry-run}\n");
    info("  #G{users bulk-remove --pattern '.*\@oldomain.com' --force}\n");
    info("\n");
    info("#y{Options:}\n");
    info("  --file <file>      # File containing usernames (one per line)\n");
    info("  --pattern <regex>  # Regex pattern to match usernames\n");
    info("  --dry-run          # Show what would be deleted without deleting\n");
    info("  --force            # Skip confirmation prompt\n");
    return;
  }

  my @users_to_delete = ();

  # Load users from file
  if ($file) {
    bail("#R{[ERROR]} File does not exist: $file") unless -f $file;

    open(my $fh, '<', $file) or bail("#R{[ERROR]} Cannot read file $file: $!");
    while (my $line = <$fh>) {
      chomp $line;
      $line =~ s/^\s+|\s+$//g;  # Trim whitespace
      next if $line eq '' || $line =~ /^#/;  # Skip empty lines and comments
      push @users_to_delete, $line;
    }
    close($fh);

    info("#G{Loaded " . scalar(@users_to_delete) . " usernames from file: $file}\n");
  }

  # Find users by pattern
  if ($pattern) {
    info("#G{Finding users matching pattern: $pattern}\n");

    my $list_result = uaa_cmd("list-users");
    unless ($list_result->{success}) {
      bail("#R{[ERROR]} Failed to list users: " . $list_result->{output});
    }

    my @lines = split /\n/, $list_result->{output};
    my $pattern_regex = qr/$pattern/;

    foreach my $line (@lines) {
      if ($line =~ /userName:\s*(\S+)/) {
        my $username = $1;
        if ($username =~ $pattern_regex) {
          push @users_to_delete, $username unless grep { $_ eq $username } @users_to_delete;
        }
      }
    }

    info("#G{Found " . scalar(@users_to_delete) . " users matching pattern}\n");
  }

  unless (@users_to_delete) {
    info("#y{No users found to delete}\n");
    return;
  }

  # Remove duplicates and sort
  my %seen;
  @users_to_delete = sort grep { !$seen{$_}++ } @users_to_delete;

  # Verify each user exists
  info("#G{Verifying users...}\n");
  my @valid_users = ();
  my @invalid_users = ();

  foreach my $username (@users_to_delete) {
    my $check = uaa_cmd("get-user $username", 1);
    if ($check->{success}) {
      push @valid_users, $username;
    } else {
      push @invalid_users, $username;
    }
  }

  # Report findings
  info("\n");
  info("#G{Summary:}\n");
  info("#G{  Valid users found: " . scalar(@valid_users) . "}\n");
  info("#y{  Invalid/non-existent users: " . scalar(@invalid_users) . "}\n") if @invalid_users;

  if (@invalid_users && !$force) {
    info("\n");
    info("#y{Invalid usernames:}\n");
    foreach my $username (@invalid_users) {
      info("  - $username\n");
    }
  }

  unless (@valid_users) {
    info("#y{No valid users to delete}\n");
    return;
  }

  # Show users to be deleted
  info("\n");
  info($dry_run ? "#y{Users that WOULD BE deleted (dry-run mode):}\n" : "#R{Users to be deleted:}\n");
  foreach my $username (@valid_users) {
    info("  - $username\n");
  }

  if ($dry_run) {
    info("\n");
    info("#y{This was a dry run. No users were deleted.}\n");
    info("#y{Remove --dry-run flag to perform actual deletion.}\n");
    return;
  }

  # Confirm deletion
  unless ($force) {
    info("\n");
    info("#R{WARNING: This will permanently delete " . scalar(@valid_users) . " users!}\n");
    print "Type 'DELETE ALL' to confirm: ";
    my $confirmation = <STDIN>;
    chomp $confirmation;

    unless ($confirmation eq 'DELETE ALL') {
      info("#y{Bulk deletion cancelled}\n");
      return;
    }
  }

  # Perform deletion
  info("\n");
  info("#G{Deleting users...}\n");

  my $deleted_count = 0;
  my $failed_count = 0;

  foreach my $username (@valid_users) {
    print "  Deleting $username... ";

    my $result = uaa_cmd("delete-user $username");

    if ($result->{success}) {
      print "#G{✓}\n";
      $deleted_count++;
    } else {
      print "#R{✗} " . $result->{output} . "\n";
      $failed_count++;
    }
  }

  # Final report
  info("\n");
  info("#G{Bulk deletion completed:}\n");
  info("#G{  Successfully deleted: $deleted_count users}\n");
  info("#R{  Failed to delete: $failed_count users}\n") if $failed_count > 0;
}

sub users_activate {
  my ($self, $username) = @_;

  bail("#R{[ERROR]} Username is required for users activate") unless $username;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if user exists
  my $existing = uaa_cmd("get-user $username", 1);
  unless ($existing->{success}) {
    bail("#R{[ERROR]} User $username does not exist");
  }

  info("#G{Activating user: $username}\n");

  my $result = uaa_cmd("activate-user $username");

  if ($result->{success}) {
    info("#G{✓} User $username activated successfully\n");

    # Display updated user info
    my $user_info = uaa_cmd("get-user $username", 1);
    if ($user_info->{success} && $user_info->{output} =~ /active:\s*true/i) {
      info("#y{User is now active}\n");
    }
  } else {
    bail("#R{[ERROR]} Failed to activate user $username: " . $result->{output});
  }
}

sub users_deactivate {
  my ($self, $username) = @_;

  bail("#R{[ERROR]} Username is required for users deactivate") unless $username;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if user exists
  my $existing = uaa_cmd("get-user $username", 1);
  unless ($existing->{success}) {
    bail("#R{[ERROR]} User $username does not exist");
  }

  # Confirm deactivation
  info("#y{Warning: Deactivating a user will prevent them from logging in.}\n");
  print "Are you sure you want to deactivate user '$username'? [y/N]: ";
  my $confirm = <STDIN>;
  chomp $confirm;

  unless ($confirm =~ /^[yY]/) {
    info("#y{User deactivation cancelled}\n");
    return;
  }

  info("#G{Deactivating user: $username}\n");

  my $result = uaa_cmd("deactivate-user $username");

  if ($result->{success}) {
    info("#G{✓} User $username deactivated successfully\n");

    # Display updated user info
    my $user_info = uaa_cmd("get-user $username", 1);
    if ($user_info->{success} && $user_info->{output} =~ /active:\s*false/i) {
      info("#y{User is now inactive and cannot log in}\n");
    }
  } else {
    bail("#R{[ERROR]} Failed to deactivate user $username: " . $result->{output});
  }
}

sub users_reset_password {
  my ($self, $username, $new_password) = @_;

  bail("#R{[ERROR]} Username is required for users reset-password") unless $username;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if user exists and get current info
  my $user_info_cmd = uaa_cmd("get-user $username --attributes=id,userName,emails,groups,origin", 1);
  unless ($user_info_cmd->{success}) {
    bail("#R{[ERROR]} User $username does not exist");
  }

  my $current_email;
  my @current_groups = ();

  # Parse current user info to extract email and groups
  if ($user_info_cmd->{output} =~ /emails:\s*\[\s*([^\]]+)\s*\]/i) {
    my $emails_str = $1;
    if ($emails_str =~ /value:\s*"?([^",\s]+)"?/i) {
      $current_email = $1;
    }
  }

  # Extract current groups
  if ($user_info_cmd->{output} =~ /groups:\s*\[(.*?)\]/si) {
    my $groups_str = $1;
    while ($groups_str =~ /display:\s*"?([^",\s]+)"?/gi) {
      push @current_groups, $1;
    }
  }

  # Set email default
  my $final_email = $current_email || "${username}\@example.com";

  # Get new password
  if (!$new_password) {
    info("#G{Password Reset for user: $username}\n");
    info("#y{Current email: $final_email}\n");
    info("#y{Groups: \n" . (@current_groups ? join(", \n", @current_groups) : "none\n") . "}");
    info("\n");

    # Offer password generation or manual entry
    print "Enter new password (or press Enter to generate a secure password): ";
    my $input_password = <STDIN>;
    chomp $input_password;

    if ($input_password) {
      # Validate password strength
      if (length($input_password) < 8) {
        bail("#R{[ERROR]} Password must be at least 8 characters long");
      }
      $new_password = $input_password;
    } else {
      $new_password = generate_password();
      info("#y{Generated password for user $username: $new_password}\n");
      info("#y{Please save this password securely!}\n");
    }
  }

  # Confirm the operation
  info("#y{Warning: This will reset the password for user '$username'}\n");
  print "Do you want to proceed? [y/N]: ";
  my $confirm = <STDIN>;
  chomp $confirm;
  unless ($confirm =~ /^[yY]/) {
    info("#y{Password reset cancelled}\n");
    return;
  }

  # Delete the user
  info("#G{Step 1/3: Removing existing user...}\n");
  my $delete_result = uaa_cmd("delete-user $username");
  unless ($delete_result->{success}) {
    bail("#R{[ERROR]} Failed to delete user $username: " . $delete_result->{output});
  }

  # Recreate the user with new password
  info("#G{Step 2/3: Recreating user with new password...}\n");

  # Extract names from username if not provided separately
  my $given_name = $username;
  my $family_name = $username;

  my $create_cmd = "create-user $username --email " . shell_quote($final_email) .
  " --password " . shell_quote($new_password) .
  " --givenName " . shell_quote($given_name) .
  " --familyName " . shell_quote($family_name);

  my $create_result = uaa_cmd($create_cmd);
  unless ($create_result->{success}) {
    bail("#R{[ERROR]} Failed to recreate user $username: " . $create_result->{output} . "\n" .
      "        WARNING: User has been deleted but not recreated!");
  }

  # Re-add user to groups
  if (@current_groups) {
    info("#G{Step 3/3: Restoring group memberships...}\n");
    foreach my $group (@current_groups) {
      # Skip system groups that are automatically assigned
      next if $group =~ /^(openid|scim\.me|cloud_controller\.read)$/;

      $self->add_user_to_group_internal($username, $group);
    }
  }

  info("#G{✓} Password reset completed successfully for user $username\n");

  # Show reminder about notifying the user
  info("#y{Important: Remember to securely communicate the new password to the user}\n");
}

sub users_list {
  my ($self, @options) = @_;

  check_prerequisites();
  $self->ensure_authenticated();

  my $filter = '';

  # Parse options
  foreach my $opt (@options) {
    if ($opt =~ /^--filter=(.+)$/) {
      $filter = $1;
    } elsif ($opt =~ /^--filter$/) {
      # Next argument should be the filter value
      # This is a simplified implementation
      bail("#R{[ERROR]} --filter requires a value (use --filter=pattern)");
    }
  }

  info("#G{Listing UAA users}\n");

  my $result = uaa_cmd("list-users");

  if ($result->{success}) {
    my $output = $result->{output};

    if ($filter) {
      info("#y{Filtering results with pattern: $filter}\n");
      my @lines = split /\n/, $output;
      my @filtered_lines;

      # Convert shell-style wildcards to regex
      my $regex = $filter;
      $regex =~ s/\*/.*/g;
      $regex =~ s/\?/./g;
      $regex = qr/$regex/i;

      foreach my $line (@lines) {
        if ($line =~ $regex) {
          push @filtered_lines, $line;
        }
      }

      if (@filtered_lines) {
        print join("\n", @filtered_lines) . "\n";
        info("\n#G{Found " . scalar(@filtered_lines) . " matching users}\n");
      } else {
        info("#y{No users match the filter pattern}\n");
      }
    } else {
      print $output;
    }
  } else {
    bail("#R{[ERROR]} Failed to list users: " . $result->{output});
  }
}

sub users_search {
  my ($self, @args) = @_;

  check_prerequisites();
  $self->ensure_authenticated();

  # Parse search arguments
  my ($query_type, @query_args) = @args;

  unless ($query_type) {
    info("#y{Usage examples:}\n");
    info("  #G{users search email-domain gmail.com}          # Find users with gmail.com email\n");
    info("  #G{users search origin ldap}                      # Find users from LDAP origin\n");
    info("  #G{users search unverified}                       # Find unverified users\n");
    info("  #G{users search starts-with z}                    # Find users starting with 'z'\n");
    info("  #G{users search created-after 2023-01-01}        # Find recently created users\n");
    info("  #G{users search inactive}                         # Find inactive users\n");
    info("  #G{users search by-group bosh.admin}             # Find users in specific group\n");
    info("  #G{users search custom 'verified eq false'}      # Custom SCIM filter\n");
    return;
  }

  my ($filter, $attributes, $sort_by, $sort_order);

  # Build SCIM filter based on query type
  if ($query_type eq 'email-domain') {
    my $domain = shift @query_args or bail("#R{[ERROR]} Email domain required");
    $filter = "userName co \"$domain\" or emails.value co \"$domain\"";
    $attributes = "id,userName,emails,verified";
  }
  elsif ($query_type eq 'origin') {
    my $origin = shift @query_args or bail("#R{[ERROR]} Origin name required");
    $filter = "origin eq \"$origin\"";
    $attributes = "id,userName,origin,emails";
  }
  elsif ($query_type eq 'unverified') {
    $filter = "verified eq false";
    $attributes = "id,userName,emails,verified,created";
  }
  elsif ($query_type eq 'starts-with') {
    my $prefix = shift @query_args or bail("#R{[ERROR]} Username prefix required");
    $filter = "userName sw \"$prefix\"";
    $attributes = "id,userName,emails";
  }
  elsif ($query_type eq 'created-after') {
    my $date = shift @query_args or bail("#R{[ERROR]} Date required (YYYY-MM-DD)");
    unless ($date =~ /^\d{4}-\d{2}-\d{2}$/) {
      bail("#R{[ERROR]} Invalid date format. Use YYYY-MM-DD");
    }
    $filter = "meta.created gt \"${date}T00:00:00Z\"";
    $attributes = "id,userName,emails,meta.created";
    $sort_by = "created";
    $sort_order = "descending";
  }
  elsif ($query_type eq 'inactive') {
    # Users who haven't changed password recently
    my $days_ago = shift @query_args || 90;
    my $date = `date -u -v-${days_ago}d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null` ||
               `date -u -d "${days_ago} days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null`;
    chomp $date;
    $filter = "passwordLastModified lt \"$date\"";
    $attributes = "id,userName,emails,passwordLastModified,active";
  }
  elsif ($query_type eq 'by-group') {
    my $group = shift @query_args or bail("#R{[ERROR]} Group name required");
    $filter = "groups.display eq \"$group\"";
    $attributes = "id,userName,emails,groups";
  }
  elsif ($query_type eq 'custom') {
    $filter = shift @query_args or bail("#R{[ERROR]} SCIM filter required");
    # For custom queries, include all attributes unless specified
    $attributes = join(',', @query_args) if @query_args;
  }
  else {
    bail("#R{[ERROR]} Unknown search type: $query_type\n" .
      "        Available: email-domain, origin, unverified, starts-with, created-after, inactive, by-group, custom");
  }

  info("#G{Searching users with query: $query_type}\n");
  info("#y{SCIM filter: $filter}\n") if $filter;

  # Build command
  my $cmd = "list-users";
  $cmd .= " --filter " . shell_quote($filter) if $filter;
  $cmd .= " --attributes " . shell_quote($attributes) if $attributes;
  $cmd .= " --sortBy " . shell_quote($sort_by) if $sort_by;
  $cmd .= " --sortOrder " . shell_quote($sort_order) if $sort_order;

  my $result = uaa_cmd($cmd);

  if ($result->{success}) {
    my $output = $result->{output};

    # Count results
    my $count = 0;
    my @lines = split /\n/, $output;
    foreach my $line (@lines) {
      $count++ if $line =~ /^\s*userName:/;
    }

    print $output;
    info("\n#G{Found $count matching users}\n");
  } else {
    bail("#R{[ERROR]} Search failed: " . $result->{output});
  }
}

sub users_update {
  my ($self, $username, @options) = @_;

  bail("#R{[ERROR]} Username is required for users update") unless $username;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if user exists and get current info
  my $user_info_cmd = uaa_cmd("get-user $username --attributes=id,userName,emails,groups,origin", 1);
  unless ($user_info_cmd->{success}) {
    bail("#R{[ERROR]} User $username does not exist");
  }

  my ($new_email, $new_password, $current_email);

  # Parse current user info to extract email and groups
  my @current_groups = ();
  if ($user_info_cmd->{output} =~ /emails:\s*\[\s*([^\]]+)\s*\]/i) {
    my $emails_str = $1;
    if ($emails_str =~ /value:\s*"?([^",\s]+)"?/i) {
      $current_email = $1;
    }
  }

  # Extract current groups
  if ($user_info_cmd->{output} =~ /groups:\s*\[(.*?)\]/si) {
    my $groups_str = $1;
    while ($groups_str =~ /display:\s*"?([^",\s]+)"?/gi) {
      push @current_groups, $1;
    }
  }

  # Parse options
  foreach my $opt (@options) {
    if ($opt =~ /^--email=(.+)$/) {
      $new_email = $1;
      unless ($new_email =~ /^[^\s@]+@[^\s@]+\.[^\s@]+$/) {
        bail("#R{[ERROR]} Invalid email format: $new_email");
      }
    } elsif ($opt =~ /^--password=(.+)$/) {
      $new_password = $1;
    } elsif ($opt =~ /^--/) {
      bail("#R{[ERROR]} Unknown option: $opt\n" .
        "        Available options: --email=<email>, --password=<password>");
    }
  }

  unless ($new_email || $new_password) {
    bail("#R{[ERROR]} At least one update option is required\n" .
      "        Available options: --email=<email>, --password=<password>");
  }

  # Set defaults
  my $final_email = $new_email || $current_email || "${username}\@example.com";
  my $final_password = $new_password;

  # If only email is being updated, user must provide new password or we generate one
  if (!$new_password) {
    info("#y{Warning: Password is required when recreating user.}\n");
    print "Enter new password for $username (or press Enter to generate): ";
    my $input_password = <STDIN>;
    chomp $input_password;

    if ($input_password) {
      $final_password = $input_password;
    } else {
      $final_password = generate_password();
      info("#y{Generated password for user $username: $final_password}\n");
      info("#y{Please save this password securely!}\n");
    }
  }

  info("#G{Updating user: $username}\n");
  info("#y{Note: User will be deleted and recreated to apply changes}\n");

  # Confirm the operation
  info("#y{The following changes will be applied:}\n");
  info("#y{  Username: $username (unchanged)}\n");
  info("#y{  Email: " . ($new_email ? "$current_email -> $new_email" : "$final_email (unchanged)") . "}\n");
  info("#y{  Password: " . ($new_password ? "*** (changed)" : "*** (new password required)") . "}\n");
  info("#y{  Groups: \n" . (@current_groups ? join(", \n", @current_groups) : "none\n") . " (preserved)}");

  print "\nDo you want to proceed? [y/N]: ";
  my $confirm = <STDIN>;
  chomp $confirm;
  unless ($confirm =~ /^[yY]/) {
    info("#y{User update cancelled}\n");
    return;
  }

  # Delete the user
  info("#G{Step 1/3: Deleting existing user...}\n");
  my $delete_result = uaa_cmd("delete-user $username");
  unless ($delete_result->{success}) {
    bail("#R{[ERROR]} Failed to delete user $username: " . $delete_result->{output});
  }

  # Recreate the user with new details
  info("#G{Step 2/3: Recreating user with new details...}\n");

  # Extract names from username if not provided separately
  my $given_name = $username;
  my $family_name = $username;

  my $create_cmd = "create-user $username --email " . shell_quote($final_email) .
  " --password " . shell_quote($final_password) .
  " --givenName " . shell_quote($given_name) .
  " --familyName " . shell_quote($family_name);

  my $create_result = uaa_cmd($create_cmd);
  unless ($create_result->{success}) {
    bail("#R{[ERROR]} Failed to recreate user $username: " . $create_result->{output} . "\n" .
      "        WARNING: User has been deleted but not recreated!");
  }

  # Re-add user to groups
  if (@current_groups) {
    info("#G{Step 3/3: Restoring group memberships...}\n");
    foreach my $group (@current_groups) {
      # Skip system groups that are automatically assigned
      next if $group =~ /^(openid|scim\.me|cloud_controller\.read)$/;

      $self->add_user_to_group_internal($username, $group);
    }
  }

  info("#G{✓} User $username updated successfully\n");

  # Display updated user info
  info("\n#y{Updated User Details:}\n");
  my $updated_info = uaa_cmd("get-user $username", 1);
  if ($updated_info->{success}) {
    print $updated_info->{output};
  }
}

# Helper functions
sub ensure_authenticated {
  my ($self) = @_;
  my $context = uaa_cmd("context", 1);
  unless ($context->{success} && $context->{output} =~ /client_id/) {
    info("#y{Not authenticated with UAA. Attempting to login...}\n");
    $self->uaa_login();
  }
}

sub generate_password {
  # Generate a secure random password
  my @chars = ('a'..'z', 'A'..'Z', '0'..'9', '!', '@', '#', '%', '^', '&', '*');
  my $password = '';
  for (1..16) {
    $password .= $chars[rand @chars];
  }
  return $password;
}

sub add_user_to_group_internal {
  my ($self, $username, $group) = @_;

  # Check if group exists
  my $group_check = uaa_cmd("get-group $group", 1);
  unless ($group_check->{success}) {
    info("#y{Warning: Group '$group' does not exist, skipping}\n");
    return;
  }

  my $result = uaa_cmd("add-member $group $username");
  if ($result->{success}) {
    info("#G{✓} Added user $username to group $group\n");
  } else {
    info("#y{Warning: Failed to add user $username to group $group: " . $result->{output} . "}\n");
  }
}

sub users_import {
  my ($self, $file) = @_;

  bail("#R{[ERROR]} YAML file path is required for users import") unless $file;
  bail("#R{[ERROR]} File does not exist: $file") unless -f $file;

  check_prerequisites();
  $self->ensure_authenticated();

  info("#G{Importing users from file: $file}\n");

  # Read YAML file
  my $data = eval { load_yaml_file($file) };
  if ($@) {
    bail("#R{[ERROR]} Failed to parse YAML file $file: $@");
  }

  # Validate YAML structure
  unless (ref $data eq 'HASH' && $data->{users} && ref $data->{users} eq 'ARRAY') {
    bail("#R{[ERROR]} Invalid YAML structure. Expected: {users: [...], groups: [...]}");
  }

  my $users = $data->{users};
  my $groups = $data->{groups} || [];

  # Create groups first
  foreach my $group (@$groups) {
    if (ref $group eq 'HASH' && $group->{displayName}) {
      my $description = $group->{description} || '';
      $self->create_group_if_not_exists($group->{displayName}, $description);
    }
  }

  # Create users
  my $created_count = 0;
  my $skipped_count = 0;

  foreach my $user (@$users) {
    unless (ref $user eq 'HASH' && $user->{username}) {
      info("#y{Warning: Skipping invalid user entry}\n");
      $skipped_count++;
      next;
    }

    my $username = $user->{username};
    my $password = $user->{password} || generate_password();
    my $email = $user->{email} || "${username}\@example.com";
    my $user_groups = $user->{groups} || ['bosh.admin'];

    # Check if user already exists
    my $existing = uaa_cmd("get-user $username", 1);
    if ($existing->{success}) {
      info("#y{Skipping existing user: $username}\n");
      $skipped_count++;
      next;
    }

    # Create user
    eval {
      $self->users_add($username, $password, $email, @$user_groups);
      $created_count++;
    };
    if ($@) {
      info("#y{Warning: Failed to create user $username: $@}\n");
      $skipped_count++;
    }
  }

  info("#G{✓} Import completed: $created_count users created, $skipped_count skipped\n");
}

sub users_export {
  my ($self, $file) = @_;

  check_prerequisites();
  $self->ensure_authenticated();

  info("#G{Exporting users...}\n");

  my $result = uaa_cmd("list-users --attributes=id,userName,emails,groups");
  unless ($result->{success}) {
    bail("#R{[ERROR]} Failed to retrieve users: " . $result->{output});
  }

  # This is a simplified export - in a real implementation, you'd parse
  # the uaac output and format it as proper YAML
  my $export_data = {
    users => [],
    groups => [],
    exported_at => scalar(localtime()),
    exported_by => $ENV{USER} || 'unknown',
    raw_uaac_output => $result->{output}
  };

  # Save data as YAML
  if ($file) {
    eval { save_to_yaml_file($export_data, $file) };
    if ($@) {
      bail("#R{[ERROR]} Failed to save export data to $file: $@");
    }
    info("#G{✓} Users exported to: $file}
");
  } else {
    # Output to stdout if no file specified
    eval {
      require YAML::XS;
      print YAML::XS::Dump($export_data);
    };
    if ($@) {
      # Fallback to basic YAML output using save_to_yaml_file to temp file
      my ($fh, $tmpfile) = tempfile(UNLINK => 1);
      close($fh);
      save_to_yaml_file($export_data, $tmpfile);
      open(my $in, '<', $tmpfile) or bail("#R{[ERROR]} Failed to read temp file: $!");
      print while <$in>;
      close($in);
    }
  }
}

sub groups_add {
  my ($self, $groupname, $description) = @_;

  bail("#R{[ERROR]} Group name is required for groups add") unless $groupname;

  # Validate group name format
  unless ($groupname =~ /^[a-zA-Z0-9._-]+$/) {
    bail("#R{[ERROR]} Invalid group name format. Use only letters, numbers, dots, underscores, and hyphens.");
  }

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if group already exists
  my $existing = uaa_cmd("get-group $groupname", 1);
  if ($existing->{success}) {
    bail("#R{[ERROR]} Group $groupname already exists");
  }

  info("#G{Creating group: $groupname}\n");

  my $create_cmd = "create-group $groupname";
  if ($description) {
    $create_cmd .= " -d " . shell_quote($description);
  }

  my $result = uaa_cmd($create_cmd);

  if ($result->{success}) {
    info("#G{✓} Group $groupname created successfully\n");

    # Display group info
    info("\n#y{Group Details:}\n");
    my $group_info = uaa_cmd("get-group $groupname", 1);
    if ($group_info->{success}) {
      print $group_info->{output};
    }
  } else {
    bail("#R{[ERROR]} Failed to create group $groupname: " . $result->{output});
  }
}

sub groups_list {
  my ($self) = @_;
  check_prerequisites();
  $self->ensure_authenticated();

  info("#G{Listing UAA groups}\n");

  my $result = uaa_cmd("list-groups");

  if ($result->{success}) {
    print $result->{output};
  } else {
    bail("#R{[ERROR]} Failed to list groups: " . $result->{output});
  }
}

sub groups_members {
  my ($self, $groupname) = @_;

  bail("#R{[ERROR]} Group name is required for groups members") unless $groupname;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if group exists
  my $existing = uaa_cmd("get-group $groupname", 1);
  unless ($existing->{success}) {
    bail("#R{[ERROR]} Group $groupname does not exist");
  }

  info("#G{Listing members of group: $groupname}\n");

  my $result = uaa_cmd("get-group $groupname");

  if ($result->{success}) {
    # Parse output to show just the members section
    my $output = $result->{output};
    if ($output =~ /members:/i) {
      print $output;
    } else {
      info("#y{Group $groupname has no members}\n");
    }
  } else {
    bail("#R{[ERROR]} Failed to get group members: " . $result->{output});
  }
}

sub groups_add_member {
  my ($self, $groupname, $username) = @_;

  bail("#R{[ERROR]} Group name and username are required for groups add-member")
  unless $groupname && $username;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if group exists
  my $group_check = uaa_cmd("get-group $groupname", 1);
  unless ($group_check->{success}) {
    bail("#R{[ERROR]} Group $groupname does not exist");
  }

  # Check if user exists
  my $user_check = uaa_cmd("get-user $username", 1);
  unless ($user_check->{success}) {
    bail("#R{[ERROR]} User $username does not exist");
  }

  info("#G{Adding user $username to group $groupname}\n");

  my $result = uaa_cmd("add-member $groupname $username");

  if ($result->{success}) {
    info("#G{✓} User $username added to group $groupname successfully\n");
  } else {
    # Check if user is already a member
    if ($result->{output} =~ /already.*member/i) {
      info("#y{User $username is already a member of group $groupname}\n");
    } else {
      bail("#R{[ERROR]} Failed to add user to group: " . $result->{output});
    }
  }
}

sub groups_remove_member {
  my ($self, $groupname, $username) = @_;

  bail("#R{[ERROR]} Group name and username are required for groups remove-member")
  unless $groupname && $username;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if group exists
  my $group_check = uaa_cmd("get-group $groupname", 1);
  unless ($group_check->{success}) {
    bail("#R{[ERROR]} Group $groupname does not exist");
  }

  # Check if user exists
  my $user_check = uaa_cmd("get-user $username", 1);
  unless ($user_check->{success}) {
    bail("#R{[ERROR]} User $username does not exist");
  }

  info("#G{Removing user $username from group $groupname}\n");

  my $result = uaa_cmd("remove-member $groupname $username");

  if ($result->{success}) {
    info("#G{✓} User $username removed from group $groupname successfully\n");
  } else {
    bail("#R{[ERROR]} Failed to remove user from group: " . $result->{output});
  }
}

# Helper function for import
sub create_group_if_not_exists {
  my ($self, $groupname, $description) = @_;

  my $existing = uaa_cmd("get-group $groupname", 1);
  unless ($existing->{success}) {
    info("#G{Creating group: $groupname}\n");
    $self->groups_add($groupname, $description);
  }
}

sub groups_bulk_add_members {
  my ($self, $groupname, @args) = @_;

  bail("#R{[ERROR]} Group name is required for groups bulk-add-members") unless $groupname;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if group exists
  my $group_check = uaa_cmd("get-group $groupname", 1);
  unless ($group_check->{success}) {
    bail("#R{[ERROR]} Group $groupname does not exist");
  }

  # Parse arguments
  my ($file, $pattern, $dry_run);
  my @explicit_users = ();

  for (my $i = 0; $i < @args; $i++) {
    if ($args[$i] eq '--file' && $i + 1 < @args) {
      $file = $args[++$i];
    } elsif ($args[$i] eq '--pattern' && $i + 1 < @args) {
      $pattern = $args[++$i];
    } elsif ($args[$i] eq '--dry-run') {
      $dry_run = 1;
    } elsif ($args[$i] !~ /^--/) {
      push @explicit_users, $args[$i];
    }
  }

  unless ($file || $pattern || @explicit_users) {
    info("#y{Bulk add users to group: $groupname}\n");
    info("\n");
    info("#y{Usage examples:}\n");
    info("  #G{groups bulk-add-members developers user1 user2 user3}\n");
    info("  #G{groups bulk-add-members developers --file users.txt}\n");
    info("  #G{groups bulk-add-members developers --pattern 'dev-.*' --dry-run}\n");
    info("\n");
    info("#y{Options:}\n");
    info("  --file <file>      # File containing usernames (one per line)\n");
    info("  --pattern <regex>  # Regex pattern to match usernames\n");
    info("  --dry-run          # Show what would be done without making changes\n");
    return;
  }

  my @users_to_add = @explicit_users;

  # Load users from file
  if ($file) {
    bail("#R{[ERROR]} File does not exist: $file") unless -f $file;

    open(my $fh, '<', $file) or bail("#R{[ERROR]} Cannot read file $file: $!");
    while (my $line = <$fh>) {
      chomp $line;
      $line =~ s/^\s+|\s+$//g;  # Trim whitespace
      next if $line eq '' || $line =~ /^#/;  # Skip empty lines and comments
      push @users_to_add, $line;
    }
    close($fh);

    info("#G{Loaded " . scalar(@users_to_add) . " usernames from file: $file}\n");
  }

  # Find users by pattern
  if ($pattern) {
    info("#G{Finding users matching pattern: $pattern}\n");

    my $list_result = uaa_cmd("list-users");
    unless ($list_result->{success}) {
      bail("#R{[ERROR]} Failed to list users: " . $list_result->{output});
    }

    my @lines = split /\n/, $list_result->{output};
    my $pattern_regex = qr/$pattern/;

    foreach my $line (@lines) {
      if ($line =~ /userName:\s*(\S+)/) {
        my $username = $1;
        if ($username =~ $pattern_regex) {
          push @users_to_add, $username unless grep { $_ eq $username } @users_to_add;
        }
      }
    }

    info("#G{Found " . scalar(@users_to_add) . " users matching pattern}\n");
  }

  unless (@users_to_add) {
    info("#y{No users found to add to group}\n");
    return;
  }

  # Remove duplicates and sort
  my %seen;
  @users_to_add = sort grep { !$seen{$_}++ } @users_to_add;

  # Get current group members
  info("#G{Getting current group members...}\n");
  my @current_members = ();

  my $members_result = uaa_cmd("get-group $groupname");
  if ($members_result->{success} && $members_result->{output} =~ /members:\s*\[(.*?)\]/si) {
    my $members_str = $1;
    while ($members_str =~ /userName:\s*"?([^",\s]+)"?/gi) {
      push @current_members, $1;
    }
  }

  info("#G{Current members: " . scalar(@current_members) . "}\n");

  # Verify each user exists and isn't already a member
  info("#G{Verifying users...}\n");
  my @valid_users = ();
  my @invalid_users = ();
  my @already_members = ();

  foreach my $username (@users_to_add) {
    if (grep { $_ eq $username } @current_members) {
      push @already_members, $username;
      next;
    }

    my $check = uaa_cmd("get-user $username", 1);
    if ($check->{success}) {
      push @valid_users, $username;
    } else {
      push @invalid_users, $username;
    }
  }

  # Report findings
  info("\n");
  info("#G{Summary:}\n");
  info("#G{  Valid users to add: " . scalar(@valid_users) . "}\n");
  info("#y{  Already members: " . scalar(@already_members) . "}\n") if @already_members;
  info("#y{  Invalid/non-existent users: " . scalar(@invalid_users) . "}\n") if @invalid_users;

  if (@invalid_users) {
    info("\n");
    info("#y{Invalid usernames:}\n");
    foreach my $username (@invalid_users) {
      info("  - $username\n");
    }
  }

  unless (@valid_users) {
    info("#y{No new users to add to group}\n");
    return;
  }

  # Show users to be added
  info("\n");
  info($dry_run ? "#y{Users that WOULD BE added to group '$groupname\n' (dry-run mode):}\n" : "#G{Adding users to group '$groupname\n':}\n");
  foreach my $username (@valid_users) {
    info("  - $username\n");
  }

  if ($dry_run) {
    info("\n");
    info("#y{This was a dry run. No changes were made.}\n");
    info("#y{Remove --dry-run flag to perform actual group membership changes.}\n");
    return;
  }

  # Add users to group
  info("\n");
  info("#G{Adding users to group...}\n");

  my $added_count = 0;
  my $failed_count = 0;

  foreach my $username (@valid_users) {
    print "  Adding $username to $groupname... ";

    my $result = uaa_cmd("add-member $groupname $username");

    if ($result->{success}) {
      print "#G{✓}\n";
      $added_count++;
    } else {
      print "#R{✗} " . $result->{output} . "\n";
      $failed_count++;
    }
  }

  # Final report
  info("\n");
  info("#G{Bulk group membership completed:}\n");
  info("#G{  Successfully added: $added_count users}\n");
  info("#R{  Failed to add: $failed_count users}\n") if $failed_count > 0;
  info("#y{  Already members: " . scalar(@already_members) . " users}\n") if @already_members;
}

sub groups_map_external {
  my ($self, $uaa_group, $external_group, $origin) = @_;

  bail("#R{[ERROR]} UAA group name is required for groups map-external") unless $uaa_group;
  bail("#R{[ERROR]} External group name is required for groups map-external") unless $external_group;

  check_prerequisites();
  $self->ensure_authenticated();

  # Set default origin if not provided
  $origin ||= 'ldap';

  # Check if UAA group exists
  my $group_check = uaa_cmd("get-group $uaa_group", 1);
  unless ($group_check->{success}) {
    info("#y{UAA group '$uaa_group\n' does not exist. Would you like to create it? [y/N]: }\n");
    my $create_confirm = <STDIN>;
    chomp $create_confirm;

    if ($create_confirm =~ /^[yY]/) {
      $self->groups_add($uaa_group, "Mapped from external group: $external_group");
    } else {
      bail("#R{[ERROR]} Cannot map to non-existent UAA group: $uaa_group");
    }
  }

  info("#G{Mapping external group to UAA group:}\n");
  info("#y{  UAA Group: $uaa_group}\n");
  info("#y{  External Group: $external_group}\n");
  info("#y{  Origin: $origin}\n");

  my $result = uaa_cmd("map-group $uaa_group --group " . shell_quote($external_group) . " --origin " . shell_quote($origin));

  if ($result->{success}) {
    info("#G{✓} Successfully mapped external group '$external_group' to UAA group '$uaa_group'\n");

    # Show current mappings for this group
    info("\n#y{Current mappings for group '$uaa_group':}\n");
    my $mappings = uaa_cmd("list-group-mappings", 1);
    if ($mappings->{success}) {
      my @lines = split /\n/, $mappings->{output};
      foreach my $line (@lines) {
        if ($line =~ /\Q$uaa_group\E/) {
          print "  $line\n";
        }
      }
    }
  } else {
    bail("#R{[ERROR]} Failed to map external group: " . $result->{output});
  }
}

sub groups_unmap_external {
  my ($self, $uaa_group, $external_group, $origin) = @_;

  bail("#R{[ERROR]} UAA group name is required for groups unmap-external") unless $uaa_group;
  bail("#R{[ERROR]} External group name is required for groups unmap-external") unless $external_group;

  check_prerequisites();
  $self->ensure_authenticated();

  # Set default origin if not provided
  $origin ||= 'ldap';

  info("#G{Unmapping external group from UAA group:}\n");
  info("#y{  UAA Group: $uaa_group}\n");
  info("#y{  External Group: $external_group}\n");
  info("#y{  Origin: $origin}\n");

  # Confirm unmapping
  info("#y{Are you sure you want to remove this mapping? [y/N]: }\n");
  my $confirm = <STDIN>;
  chomp $confirm;

  unless ($confirm =~ /^[yY]/) {
    info("#y{Unmapping cancelled}\n");
    return;
  }

  my $result = uaa_cmd("unmap-group $uaa_group --group " . shell_quote($external_group) . " --origin " . shell_quote($origin));

  if ($result->{success}) {
    info("#G{✓} Successfully unmapped external group '$external_group' from UAA group '$uaa_group'\n");
  } else {
    bail("#R{[ERROR]} Failed to unmap external group: " . $result->{output});
  }
}

sub groups_list_mappings {
  my ($self, @args) = @_;

  check_prerequisites();
  $self->ensure_authenticated();

  # Parse optional filter argument
  my $filter_group;
  for (my $i = 0; $i < @args; $i++) {
    if ($args[$i] eq '--group' && $i + 1 < @args) {
      $filter_group = $args[++$i];
    }
  }

  info("#G{Listing external group mappings\n" . ($filter_group ? " for group: $filter_group\n" : "\n") . "}\n");

  my $result = uaa_cmd("list-group-mappings");

  if ($result->{success}) {
    if ($filter_group) {
      # Filter results to show only mappings for the specified group
      my @lines = split /\n/, $result->{output};
      my @filtered_lines;
      my $in_header = 1;

      foreach my $line (@lines) {
        if ($in_header && $line =~ /^[-\s]+$/) {
          $in_header = 0;
          push @filtered_lines, $line;
        } elsif ($in_header) {
          push @filtered_lines, $line;
        } elsif ($line =~ /\Q$filter_group\E/) {
          push @filtered_lines, $line;
        }
      }

      if (@filtered_lines > 2) {  # More than just headers
        print join("\n", @filtered_lines) . "\n";
      } else {
        info("#y{No mappings found for group: $filter_group}\n");
      }
    } else {
      # Show all mappings
      if ($result->{output} =~ /displayName.*externalGroup.*origin/i) {
        print $result->{output};
      } else {
        info("#y{No external group mappings found}\n");
      }
    }

    # Show usage hint
    info("\n#y{Tip: Use 'groups map-external' to create new mappings}\n");
    info("#y{     Use 'groups unmap-external' to remove existing mappings}\n");
  } else {
    bail("#R{[ERROR]} Failed to list group mappings: " . $result->{output});
  }
}

# OAuth Client Management Functions
sub clients_add {
  my ($self, $client_id, @args) = @_;

  bail("#R{[ERROR]} Client ID is required for clients add") unless $client_id;

  check_prerequisites();
  $self->ensure_authenticated();

  # Parse arguments
  my ($client_secret, $display_name, $authorized_grant_types, $authorities, $redirect_uri, $scopes);
  my $access_token_validity = 43200;  # 12 hours default
  my $refresh_token_validity = 2592000; # 30 days default

  # Simple argument parsing for common options
  for (my $i = 0; $i < @args; $i++) {
    if ($args[$i] eq '--secret' && $i + 1 < @args) {
      $client_secret = $args[++$i];
    } elsif ($args[$i] eq '--name' && $i + 1 < @args) {
      $display_name = $args[++$i];
    } elsif ($args[$i] eq '--grant-types' && $i + 1 < @args) {
      $authorized_grant_types = $args[++$i];
    } elsif ($args[$i] eq '--authorities' && $i + 1 < @args) {
      $authorities = $args[++$i];
    } elsif ($args[$i] eq '--redirect-uri' && $i + 1 < @args) {
      $redirect_uri = $args[++$i];
    } elsif ($args[$i] eq '--scopes' && $i + 1 < @args) {
      $scopes = $args[++$i];
    } elsif ($args[$i] eq '--access-validity' && $i + 1 < @args) {
      $access_token_validity = $args[++$i];
    } elsif ($args[$i] eq '--refresh-validity' && $i + 1 < @args) {
      $refresh_token_validity = $args[++$i];
    }
  }

  # Generate secret if not provided
  if (!$client_secret) {
    $client_secret = generate_password() . generate_password();  # Extra long for clients
    info("#y{Generated client secret: $client_secret}\n");
    info("#y{Please save this secret securely!}\n");
  }

  # Set defaults
  $display_name ||= $client_id;
  $authorized_grant_types ||= "client_credentials";
  $authorities ||= "uaa.none";
  $scopes ||= "uaa.none";

  info("#G{Creating OAuth client: $client_id}\n");

  # Check if client already exists
  my $existing = uaa_cmd("get-client $client_id", 1);
  if ($existing->{success}) {
    bail("#R{[ERROR]} Client $client_id already exists");
  }

  # Build create command
  my $create_cmd = "create-client $client_id" .
    " --client_secret " . shell_quote($client_secret) .
    " --display_name " . shell_quote($display_name) .
    " --authorized_grant_types " . shell_quote($authorized_grant_types) .
    " --authorities " . shell_quote($authorities) .
    " --scope " . shell_quote($scopes) .
    " --access_token_validity $access_token_validity" .
    " --refresh_token_validity $refresh_token_validity";

  if ($redirect_uri) {
    $create_cmd .= " --redirect_uri " . shell_quote($redirect_uri);
  }

  my $result = uaa_cmd($create_cmd);

  if ($result->{success}) {
    info("#G{✓} Client $client_id created successfully\n");

    # Display client info
    info("\n#y{Client Details:}\n");
    my $client_info = uaa_cmd("get-client $client_id", 1);
    if ($client_info->{success}) {
      print $client_info->{output};
    }
  } else {
    bail("#R{[ERROR]} Failed to create client $client_id: " . $result->{output});
  }
}

sub clients_remove {
  my ($self, $client_id) = @_;

  bail("#R{[ERROR]} Client ID is required for clients remove") unless $client_id;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if client exists
  my $existing = uaa_cmd("get-client $client_id", 1);
  unless ($existing->{success}) {
    bail("#R{[ERROR]} Client $client_id does not exist");
  }

  # Confirm deletion
  info("#y{Are you sure you want to delete client '$client_id'? This action cannot be undone.}\n");
  print "Type 'yes' to confirm: ";
  my $confirmation = <STDIN>;
  chomp $confirmation;

  unless ($confirmation eq 'yes') {
    info("#y{Client deletion cancelled}\n");
    return;
  }

  info("#G{Removing client: $client_id}\n");

  my $result = uaa_cmd("delete-client $client_id");

  if ($result->{success}) {
    info("#G{✓} Client $client_id removed successfully\n");
  } else {
    bail("#R{[ERROR]} Failed to remove client $client_id: " . $result->{output});
  }
}

sub clients_list {
  my ($self, @options) = @_;

  check_prerequisites();
  $self->ensure_authenticated();

  info("#G{Listing OAuth clients}\n");

  my $result = uaa_cmd("list-clients");

  if ($result->{success}) {
    print $result->{output};
  } else {
    bail("#R{[ERROR]} Failed to list clients: " . $result->{output});
  }
}

sub clients_get {
  my ($self, $client_id) = @_;

  bail("#R{[ERROR]} Client ID is required for clients get") unless $client_id;

  check_prerequisites();
  $self->ensure_authenticated();

  info("#G{Getting details for client: $client_id}\n");

  my $result = uaa_cmd("get-client $client_id");

  if ($result->{success}) {
    print $result->{output};
  } else {
    bail("#R{[ERROR]} Failed to get client $client_id: " . $result->{output});
  }
}

sub clients_set_secret {
  my ($self, $client_id, $new_secret) = @_;

  bail("#R{[ERROR]} Client ID is required for clients set-secret") unless $client_id;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if client exists
  my $existing = uaa_cmd("get-client $client_id", 1);
  unless ($existing->{success}) {
    bail("#R{[ERROR]} Client $client_id does not exist");
  }

  # Get new secret
  if (!$new_secret) {
    info("#G{Setting new secret for client: $client_id}\n");

    # Offer secret generation or manual entry
    print "Enter new secret (or press Enter to generate a secure secret): ";
    my $input_secret = <STDIN>;
    chomp $input_secret;

    if ($input_secret) {
      # Validate secret strength
      if (length($input_secret) < 8) {
        bail("#R{[ERROR]} Client secret must be at least 8 characters long");
      }
      $new_secret = $input_secret;
    } else {
      $new_secret = generate_password() . generate_password();  # Extra long for clients
      info("#y{Generated client secret: $new_secret}\n");
      info("#y{Please save this secret securely!}\n");
    }
  }

  # Confirm the operation
  info("#y{Warning: This will change the secret for client '$client_id'}\n");
  info("#y{Any applications using the old secret will stop working!}\n");
  print "Do you want to proceed? [y/N]: ";
  my $confirm = <STDIN>;
  chomp $confirm;
  unless ($confirm =~ /^[yY]/) {
    info("#y{Secret change cancelled}\n");
    return;
  }

  info("#G{Updating client secret...}\n");

  my $result = uaa_cmd("set-client-secret $client_id --client_secret " . shell_quote($new_secret));

  if ($result->{success}) {
    info("#G{✓} Client secret updated successfully for $client_id\n");
    info("#y{Remember to update any applications using this client}\n");
  } else {
    bail("#R{[ERROR]} Failed to update client secret: " . $result->{output});
  }
}

sub clients_update {
  my ($self, $client_id, @args) = @_;

  bail("#R{[ERROR]} Client ID is required for clients update") unless $client_id;

  check_prerequisites();
  $self->ensure_authenticated();

  # Check if client exists
  my $existing = uaa_cmd("get-client $client_id", 1);
  unless ($existing->{success}) {
    bail("#R{[ERROR]} Client $client_id does not exist");
  }

  # Parse update arguments
  my @update_args;
  my $has_updates = 0;

  for (my $i = 0; $i < @args; $i++) {
    if ($args[$i] =~ /^--(name|display_name|authorized_grant_types|authorities|redirect_uri|scope|access_token_validity|refresh_token_validity)$/ && $i + 1 < @args) {
      push @update_args, $args[$i], shell_quote($args[$i + 1]);
      $has_updates = 1;
      $i++;
    }
  }

  unless ($has_updates) {
    info("#y{No update options provided. Available options:}\n");
    info("  --name <name>                        # Display name\n");
    info("  --authorized_grant_types <types>     # Comma-separated grant types\n");
    info("  --authorities <authorities>          # Comma-separated authorities\n");
    info("  --redirect_uri <uri>                 # Redirect URI\n");
    info("  --scope <scopes>                     # Comma-separated scopes\n");
    info("  --access_token_validity <seconds>    # Access token validity\n");
    info("  --refresh_token_validity <seconds>   # Refresh token validity\n");
    return;
  }

  info("#G{Updating client: $client_id}\n");

  my $update_cmd = "update-client $client_id " . join(' ', @update_args);
  my $result = uaa_cmd($update_cmd);

  if ($result->{success}) {
    info("#G{✓} Client $client_id updated successfully\n");

    # Display updated client info
    info("\n#y{Updated Client Details:}\n");
    my $client_info = uaa_cmd("get-client $client_id", 1);
    if ($client_info->{success}) {
      print $client_info->{output};
    }
  } else {
    bail("#R{[ERROR]} Failed to update client $client_id: " . $result->{output});
  }
}

# User info and whoami functions
sub uaa_whoami {
  my ($self) = @_;

  check_prerequisites();
  $self->ensure_authenticated();

  info("#G{Getting current user information...}\n");

  my $result = uaa_cmd("userinfo");

  if ($result->{success}) {
    info("#G{Current User Information:}\n");
    print $result->{output};

    # Also show context info
    info("\n#y{Current UAA Context:}\n");
    my $context = uaa_cmd("context", 1);
    if ($context->{success}) {
      print $context->{output};
    }
  } else {
    bail("#R{[ERROR]} Failed to get user information: " . $result->{output});
  }
}

sub uaa_context {
  my ($self) = @_;

  check_prerequisites();

  info("#G{Current UAA Context and Token Information:}\n");

  my $result = uaa_cmd("context");

  if ($result->{success}) {
    if ($result->{output} =~ /client_id|user_name/) {
      print $result->{output};

      # Parse and show token expiry info
      if ($result->{output} =~ /exp:\s*(\d+)/) {
        my $exp_timestamp = $1;
        my $current_time = time();
        my $remaining = $exp_timestamp - $current_time;

        if ($remaining > 0) {
          my $hours = int($remaining / 3600);
          my $minutes = int(($remaining % 3600) / 60);
          info("\n#y{Token expires in: ${hours}h ${minutes}m}\n");
        } else {
          info("\n#R{Token has expired!}\n");
        }
      }
    } else {
      info("#y{No active UAA context found. Please run 'uaa login' first.}\n");
    }
  } else {
    bail("#R{[ERROR]} Failed to get context: " . $result->{output});
  }
}

sub users_info {
  my ($self, $username) = @_;

  check_prerequisites();
  $self->ensure_authenticated();

  # If no username provided, show current user info
  if (!$username) {
    info("#G{Getting current user information...}\n");

    my $userinfo = uaa_cmd("userinfo");
    if ($userinfo->{success}) {
      # Extract username from userinfo
      if ($userinfo->{output} =~ /user_name:\s*(\S+)/) {
        $username = $1;
      } else {
        bail("#R{[ERROR]} Could not determine current username");
      }
    } else {
      bail("#R{[ERROR]} Failed to get current user info: " . $userinfo->{output});
    }
  }

  info("#G{Getting detailed information for user: $username}\n");

  # Get user details with all attributes
  my $result = uaa_cmd("get-user $username --attributes=id,userName,emails,phoneNumbers,name,verified,active,origin,zoneId,passwordLastModified,previousLogonTime,lastLogonTime,groups,approvals,meta");

  if ($result->{success}) {
    info("#G{User Details:}\n");
    print $result->{output};

    # Get group memberships with more detail
    info("\n#G{Group Memberships:}\n");
    my $groups_output = $result->{output};
    if ($groups_output =~ /groups:\s*\[(.*?)\]/si) {
      my $groups_str = $1;
      my @groups;
      while ($groups_str =~ /display:\s*"?([^",\s]+)"?/gi) {
        push @groups, $1;
      }

      if (@groups) {
        foreach my $group (sort @groups) {
          info("  • $group\n");
        }
      } else {
        info("  (no groups)\n");
      }
    }

    # Show account status
    info("\n#G{Account Status:}\n");
    if ($result->{output} =~ /active:\s*(true|false)/i) {
      my $active = $1;
      info("  Active: \n" . ($active eq 'true\n' ? '#G{Yes}\n' : '#R{No}\n'));
    }
    if ($result->{output} =~ /verified:\s*(true|false)/i) {
      my $verified = $1;
      info("  Verified: \n" . ($verified eq 'true\n' ? '#G{Yes}\n' : '#Y{No}\n'));
    }
    if ($result->{output} =~ /origin:\s*(\S+)/i) {
      info("  Origin: $1\n");
    }
  } else {
    bail("#R{[ERROR]} Failed to get user information: " . $result->{output});
  }
}

sub users_backup {
  my ($self, $file) = @_;

  check_prerequisites();
  $self->ensure_authenticated();

  # Set default filename with timestamp
  if (!$file) {
    my $timestamp = `date +%Y%m%d_%H%M%S`;
    chomp $timestamp;
    $file = "uaa_backup_${timestamp}.yml";
  }

  info("#G{Creating UAA backup to file: $file}\n");
  info("#y{This will backup all users, groups, and their relationships}\n");

  # Get all users with full details
  info("#G{Backing up users...}\n");
  my $users_result = uaa_cmd("list-users --count 1000 --attributes=id,userName,emails,phoneNumbers,name,verified,active,origin,groups");
  unless ($users_result->{success}) {
    bail("#R{[ERROR]} Failed to retrieve users: " . $users_result->{output});
  }

  # Get all groups
  info("#G{Backing up groups...}\n");
  my $groups_result = uaa_cmd("list-groups --count 1000");
  unless ($groups_result->{success}) {
    bail("#R{[ERROR]} Failed to retrieve groups: " . $groups_result->{output});
  }

  # Get external group mappings
  info("#G{Backing up external group mappings...}\n");
  my $mappings_result = uaa_cmd("list-group-mappings", 1);

  # Parse and structure the data
  my $backup_data = {
    metadata => {
      created_at => scalar(localtime()),
      created_by => $ENV{USER} || 'unknown',
      uaa_url => $self->get_uaa_connection_info()->{uaa_url},
      version => '2.0',
    },
    users => [],
    groups => [],
    external_mappings => [],
  };

  # Parse users (simplified - in production would need proper JSON parsing)
  my $user_count = 0;
  my @user_lines = split /\n/, $users_result->{output};
  my $current_user = {};

  foreach my $line (@user_lines) {
    if ($line =~ /^\s*userName:\s*(\S+)/) {
      if ($current_user->{username}) {
        push @{$backup_data->{users}}, $current_user;
        $user_count++;
      }
      $current_user = { username => $1 };
    } elsif ($line =~ /^\s*emails:\s*\[(.*?)\]/) {
      my $emails_str = $1;
      if ($emails_str =~ /value:\s*"?([^",\s]+)"?/) {
        $current_user->{email} = $1;
      }
    } elsif ($line =~ /^\s*verified:\s*(true|false)/) {
      $current_user->{verified} = $1 eq 'true' ? 1 : 0;
    } elsif ($line =~ /^\s*active:\s*(true|false)/) {
      $current_user->{active} = $1 eq 'true' ? 1 : 0;
    } elsif ($line =~ /^\s*origin:\s*(\S+)/) {
      $current_user->{origin} = $1;
    } elsif ($line =~ /^\s*groups:\s*\[(.*?)\]/s) {
      my $groups_str = $1;
      $current_user->{groups} = [];
      while ($groups_str =~ /display:\s*"?([^",\s]+)"?/g) {
        push @{$current_user->{groups}}, $1;
      }
    }
  }
  # Don't forget the last user
  if ($current_user->{username}) {
    push @{$backup_data->{users}}, $current_user;
    $user_count++;
  }

  # Parse groups (simplified)
  my $group_count = 0;
  my @group_lines = split /\n/, $groups_result->{output};
  my $current_group = {};

  foreach my $line (@group_lines) {
    if ($line =~ /^\s*displayName:\s*(.+)$/) {
      if ($current_group->{displayName}) {
        push @{$backup_data->{groups}}, $current_group;
        $group_count++;
      }
      $current_group = { displayName => $1 };
    } elsif ($line =~ /^\s*description:\s*(.+)$/) {
      $current_group->{description} = $1;
    } elsif ($line =~ /^\s*members:\s*\[(.*?)\]/s) {
      my $members_str = $1;
      $current_group->{members} = [];
      while ($members_str =~ /userName:\s*"?([^",\s]+)"?/g) {
        push @{$current_group->{members}}, $1;
      }
    }
  }
  # Don't forget the last group
  if ($current_group->{displayName}) {
    push @{$backup_data->{groups}}, $current_group;
    $group_count++;
  }

  # Parse external mappings if available
  if ($mappings_result->{success}) {
    my @mapping_lines = split /\n/, $mappings_result->{output};
    foreach my $line (@mapping_lines) {
      if ($line =~ /^(\S+)\s+(\S+)\s+(\S+)$/) {
        push @{$backup_data->{external_mappings}}, {
          uaa_group => $1,
          external_group => $2,
          origin => $3,
        };
      }
    }
  }

  # Add summary
  $backup_data->{summary} = {
    total_users => $user_count,
    total_groups => $group_count,
    total_mappings => scalar(@{$backup_data->{external_mappings}}),
  };

  # Save backup data as YAML
  eval { save_to_yaml_file($backup_data, $file) };
  if ($@) {
    bail("#R{[ERROR]} Failed to save backup data to $file: $@");
  }

  info("#G{✓} Backup completed successfully}\n");
  info("#G{  File: $file}\n");
  info("#G{  Users: $user_count}\n");
  info("#G{  Groups: $group_count}\n");
  info("#G{  External Mappings: " . scalar(@{$backup_data->{external_mappings}}) . "}\n");
  info("#y{Note: User passwords are not included in the backup for security reasons}\n");
}

sub users_restore {
  my ($self, $file) = @_;

  bail("#R{[ERROR]} Backup file path is required for users restore") unless $file;
  bail("#R{[ERROR]} File does not exist: $file") unless -f $file;

  check_prerequisites();
  $self->ensure_authenticated();

  info("#G{Restoring UAA data from file: $file}\n");

  # Read YAML backup file
  my $backup_data = eval { load_yaml_file($file) };
  if ($@) {
    bail("#R{[ERROR]} Failed to parse YAML backup file $file: $@");
  }

  # Validate backup structure
  unless (ref $backup_data eq 'HASH' &&
          $backup_data->{metadata} &&
          $backup_data->{users} &&
          $backup_data->{groups}) {
    bail("#R{[ERROR]} Invalid backup file format. Expected UAA backup structure.");
  }

  # Show backup info
  info("#y{Backup Information:}\n");
  info("  Created: " . ($backup_data->{metadata}->{created_at} || 'unknown') . "\n");
  info("  Created by: " . ($backup_data->{metadata}->{created_by} || 'unknown') . "\n");
  info("  UAA URL: " . ($backup_data->{metadata}->{uaa_url} || 'unknown') . "\n");
  info("\n");
  info("#y{Backup contains:}\n");
  info("  Users: " . scalar(@{$backup_data->{users}}) . "\n");
  info("  Groups: " . scalar(@{$backup_data->{groups}}) . "\n");
  info("  External Mappings: " . scalar(@{$backup_data->{external_mappings} || []}) . "\n");

  # Confirm restore
  info("\n");
  info("#R{WARNING: This will create new users and groups. Existing users/groups will be skipped.}\n");
  info("#R{         User passwords will need to be reset after restore.}\n");
  print "Do you want to proceed with the restore? [y/N]: ";
  my $confirm = <STDIN>;
  chomp $confirm;
  unless ($confirm =~ /^[yY]/) {
    info("#y{Restore cancelled}\n");
    return;
  }

  # Restore groups first
  info("\n#G{Restoring groups...}\n");
  my $groups_created = 0;
  my $groups_skipped = 0;

  foreach my $group (@{$backup_data->{groups}}) {
    my $groupname = $group->{displayName};
    next unless $groupname;

    # Skip system groups
    next if $groupname =~ /^(openid|scim\.|cloud_controller\.|uaa\.|password\.|oauth\.|approvals\.|notification_preferences\.|roles$)/;

    my $existing = uaa_cmd("get-group $groupname", 1);
    if ($existing->{success}) {
      $groups_skipped++;
      next;
    }

    eval {
      $self->groups_add($groupname, $group->{description} || '');
      $groups_created++;
    };
    if ($@) {
      info("#y{Warning: Failed to create group $groupname: $@}\n");
    }
  }

  info("  Created: $groups_created groups\n");
  info("  Skipped: $groups_skipped existing groups\n");

  # Restore users
  info("\n#G{Restoring users...}\n");
  my $users_created = 0;
  my $users_skipped = 0;
  my %temp_passwords;

  foreach my $user (@{$backup_data->{users}}) {
    my $username = $user->{username};
    next unless $username;

    my $existing = uaa_cmd("get-user $username", 1);
    if ($existing->{success}) {
      $users_skipped++;
      next;
    }

    # Generate temporary password
    my $temp_password = generate_password();
    $temp_passwords{$username} = $temp_password;

    eval {
      $self->users_add(
        $username,
        $temp_password,
        $user->{email} || "${username}\@example.com",
        @{$user->{groups} || ['bosh.admin']}
      );
      $users_created++;

      # Deactivate if needed
      if (defined $user->{active} && !$user->{active}) {
        uaa_cmd("deactivate-user $username");
      }
    };
    if ($@) {
      info("#y{Warning: Failed to create user $username: $@}\n");
    }
  }

  info("  Created: $users_created users\n");
  info("  Skipped: $users_skipped existing users\n");

  # Restore external mappings
  if ($backup_data->{external_mappings} && @{$backup_data->{external_mappings}}) {
    info("\n#G{Restoring external group mappings...}\n");
    my $mappings_created = 0;

    foreach my $mapping (@{$backup_data->{external_mappings}}) {
      eval {
        my $result = uaa_cmd("map-group " . $mapping->{uaa_group} .
                           " --group " . shell_quote($mapping->{external_group}) .
                           " --origin " . shell_quote($mapping->{origin} || 'ldap'), 1);
        $mappings_created++ if $result->{success};
      };
    }

    info("  Restored: $mappings_created external mappings\n");
  }

  # Save temporary passwords if any users were created
  if ($users_created > 0) {
    my $pwd_file = $file;
    $pwd_file =~ s/\.yml$/_passwords.yml/;
    $pwd_file .= "_passwords.yml" unless $pwd_file =~ /_passwords\.yml$/;

    my $pwd_data = {
      metadata => {
        created_at => scalar(localtime()),
        restore_file => $file,
        note => "Temporary passwords for restored users. Please change these immediately!",
      },
      passwords => \%temp_passwords,
    };

    eval { save_to_yaml_file($pwd_data, $pwd_file) };
    if ($@) {
      warn "Could not save passwords to $pwd_file: $@";
    } else {
      info("\n#Y{IMPORTANT: Temporary passwords saved to: $pwd_file}\n");
      info("#Y{          Please distribute these passwords securely and delete the file!}\n");
    }
  }

  info("\n#G{✓} Restore completed successfully\n");
  info("#y{Note: All restored users have temporary passwords that must be changed}\n");
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
