package Genesis::Hook::Addon::BOSH::PrintEnv v3.3.0;

use strict;
use warnings;
use v5.20; # Genesis supports min perl v5.20.

# Parent class inheritance
use parent qw(Genesis::Hook::Addon);

# Import required functions
use Genesis qw/bail info/;
# TODO: Can we use JSON::PP here???
use JSON::PP;

sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
  return $obj;
}

sub cmd_details {
  my ($self) = @_;
  my $call_with_env = $self->env->get_call_path_with_env();

  return
		"All environment variables needed for targeting BOSH.\n" .
		"Use with: #G{eval \"\$($call_with_env do print-env)\"}\n\n" .
		"Supports the following #y{options}:\n\n" .
		"#y{--bosh}             print the environment variables needed to connect to the\n" .
		"                   BOSH director (BOSH_*)\n\n" .
		"#y{--credhub}          print the environment variables needed to connect to\n" .
		"                   credhub (CREDHUB_*)\n\n" .
		"#y{--ssh}              print the script needed to connect to the BOSH director using\n" .
		"                   SSH\n\n" .
		"#y{--key-path} #B{<path>}  specify the path of the SSH key to be created.  By default,\n" .
		"                   a temporary path will be used.\n\n" .
		"#y{--with-proxy}       also include the BOSH_ALL_PROXY setup for using socks5 proxy.\n" .
		"                   This will also include the SSH key setup as it is required\n" .
		"                   for connecting to the proxy.\n\n" .
		"#Yi{NOTE:}  If none of --bosh, --credhub, or --ssh is specified, all will be printed.\n\n" .
		"Consider using\n".
		"[[  >> #G{$call_with_env bosh}#y{<bosh options>} #B{<subcommand and args>}\n".
		"instead, as it doesn't pollute the environment with persistant variables.  ".
		"See #G{$call_with_env bosh --help} for more details.\n\n";
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;

  # Parse options
  my %options = $self->parse_options([
      'bosh',
      'credhub',
      'ssh',
      'with-proxy',
      'key-path=s',
    ]);

  # Print all if nothing explicitly selected
  if (!$options{bosh} && !$options{credhub} && !$options{ssh}) {
    $options{bosh} = 1;
    $options{credhub} = 1;
    $options{ssh} = 1;
  }

  # Get exodus data
  my $exodus_data = $self->exodus_data();

  # Extract host address from URL
  my $host_addr = $exodus_data->{url} || '';
  $host_addr =~ s{^https?://}{};
  $host_addr =~ s{:[0-9]+$}{};

  my @output = ();

	# FIXME: BOSH USER CRED SUPPORT - this needs to be updated to use the user's creds, depending on availability and the config setting
  # BOSH environment variables
  if ($options{bosh}) {
    push @output, sprintf('export BOSH_ENVIRONMENT=%s', _shell_quote($exodus_data->{url} || ''));
    push @output, sprintf('export BOSH_CA_CERT="$(echo -e %s)"', _shell_quote($exodus_data->{ca_cert} || ''));
    push @output, sprintf('export BOSH_CLIENT=%s', _shell_quote($exodus_data->{admin_username} || ''));
    push @output, sprintf('export BOSH_CLIENT_SECRET=%s', _shell_quote($exodus_data->{admin_password} || ''));
  }

  # Credhub environment variables
  if ($options{credhub}) {
    push @output, sprintf('export CREDHUB_SERVER=%s', _shell_quote($exodus_data->{credhub_url} || ''));
    push @output, sprintf('export CREDHUB_CLIENT=%s', _shell_quote($exodus_data->{credhub_username} || ''));
    push @output, sprintf('export CREDHUB_SECRET=%s', _shell_quote($exodus_data->{credhub_password} || ''));

    my $ca_cert = ($exodus_data->{ca_cert} || '') . ($exodus_data->{credhub_ca_cert} || '');
    push @output, sprintf('export CREDHUB_CA_CERT="$(echo -e %s)"', _shell_quote($ca_cert));
  }

  # SSH key and proxy setup
  if ($options{ssh} || $options{'with-proxy'}) {
    my $path = $options{'key-path'} || '$(mktemp)';

    # Check if path exists and is writable (if specified)
    if ($options{'key-path'}) {
      # This is effectively the same logic as the bash script:
      # if mkdir "$path"; then rmdir "$path"; elif [[ -e $path ]]; then ...

      my $can_create = 0;
      if (eval { mkdir($path); $can_create = 1; rmdir($path); 1 }) {
        # We could create and remove a directory at this path, so we're good
      } elsif (-e $path) {
        bail("Can't use $path for key location; file (or directory) already exists.");
      } else {
        bail("Can't use $path for key location; cannot write to $path");
      }
    }

    push @output, "ssh_key=$path";
    push @output, "cat << EOF > \${ssh_key}";
    push @output, $exodus_data->{netop_sshkey} || '';
    push @output, "EOF";
    push @output, "chmod 0400 \${ssh_key}";

    if ($options{'with-proxy'}) {
      push @output, sprintf(
        'export BOSH_ALL_PROXY=ssh+socks5://netop@%s:22?private-key=${ssh_key}',
        $host_addr
      );
    }
  }

  # Output results
  print join("\n", @output), "\n";

  return $self->done();
}

# Helper function to properly quote a string for shell
sub _shell_quote {
  my ($string) = @_;
  # Use JSON encoding which ensures proper escaping for shell
  my $json = JSON::PP::encode_json($string);
  # Remove the surrounding quotes that JSON adds
  $json =~ s/^"(.*)"$/$1/;
  return $json;
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
