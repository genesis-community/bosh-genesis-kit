package Genesis::Hook::Addon::BOSH v4.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info warning error run workdir mkfile_or_fail read_json_from/;

# init - Initialize the hook and check minimum Genesis version {{{
sub init {
	my ($class, %ops) = @_;
	my $self = $class->SUPER::init(%ops);

	$self->check_minimum_genesis_version('3.1.0');
	return $self;
}

# }}}

# cmd_details - Return command descriptions for available addon commands {{{
sub cmd_details {
	return {
		alias => "Set up a local bosh alias for a director",
		login => "Log into an (aliased) director",
		logout => "Log out of an (aliased) director",
		ssh => "SSH into the BOSH director",
	};
}

# }}}

# perform - Main method that dispatches to specific addon commands {{{
sub perform {
	my ($self) = @_;

	my $script = $self->{script};
	$ENV{BOSH_URL} = $self->bosh->{url};

	return $self->setup_alias if ($script eq 'alias');
	return $self->ssh_to_director if ($script eq 'ssh');

	bail("Unknown addon script: %s", $script//'<undef>')
		unless $script && $script =~ /^(login|logout)$/;

	$self->has_alias() || $self->setup_alias(1);
	return $self->login if ($script eq 'login');
	return $self->logout if ($script eq 'logout');
}

# }}}

# setup_alias - Set up a local bosh alias for the director {{{
sub setup_alias {
	my ($self, $silent) = @_;

	my ($output, $rc, $stderr) = $self->bosh->execute(
		{interactive => 0},
		'alias-env', '--tty', $self->env->name
	);

	$output =~ s/^User.*$//m; # Remove User line as done in bash
	info($output) unless $silent;
	return $self->done(1);
}

# }}}

# has_alias - Check if a BOSH alias exists for the environment {{{
sub has_alias {
	my ($self) = @_;

	my $out = read_json_from($self->bosh->execute({interactive => 0}, 'envs', '--json'));
	my $envs = $out->{Tables}[0]{Rows} || [];
	return 0 unless $envs && @$envs;

	my $env_name = $self->env->name;
	return scalar(grep { $_ eq $env_name } map { $_->{alias} } @$envs);
}

# }}}

# is_logged_in - Check if logged into the BOSH director {{{
sub is_logged_in {
	my ($self) = @_;

	# Remove any existing BOSH environment variables
	delete @ENV{qw/BOSH_CLIENT BOSH_CLIENT_SECRET BOSH_CA_CERT BOSH_ENVIRONMENT/};

	my $bosh = $self->bosh;
	my ($out,$rc,$err) = read_json_from(
		run($self->bosh->command, '-e', $self->env->name, 'env', '--json')
	);
	return 0 if $err || $rc; # If there's an error, assume not logged in
	my $user = $out->{Tables}[0]{Rows}[0]{user};

	return 0 if (!$user || $user eq '(not logged in)');
	my $target_user = $ENV{BOSH_USER} || 'admin';
	if ($user ne $target_user) {
		info(
			"Logged in as #C{%s}, expected to be #C{%s}",
			$user, $target_user
		);
		return 0;
	}

	info("Logged in as #C{$user}\n");
	return 1;
}

# }}}

# login - Log into the BOSH director {{{
sub login {
	my ($self) = @_;
	my $bosh = $self->bosh;

	# Create a temporary file with login credentials
	my $login_file = workdir() . "/.bosh_login";
	my $username = $ENV{BOSH_USER} || 'admin';
	my $password = $ENV{BOSH_PASSWORD} || $self->vault->get($ENV{GENESIS_SECRETS_BASE} . "users/" . $username, "password");;
	mkfile_or_fail($login_file, 0600, "$username\n$password\n");

	# Remove any existing BOSH environment variables
	delete @ENV{qw/BOSH_CLIENT BOSH_CLIENT_SECRET BOSH_CA_CERT BOSH_ENVIRONMENT/};

	# Execute login command
	info("Logging you in as user '$username'...");
	my ($output, $rc) = run(
		'cat "$1" | "$2" -e "$3" login', $login_file, $self->bosh->command, $self->env->name
	);

	if ($rc != 0) {
		error("Failed to log in: \n$output");
		return $self->done(0);
	}
	if (!$self->is_logged_in()) {
		error("Failed to log in to BOSH director");
		return $self->done(0);
	}

	return $self->done(1);
}

# }}}

# logout - Log out of the BOSH director {{{
sub logout {
	my ($self) = @_;
	if (!$self->is_logged_in()) {
		info("You are not logged in to the BOSH director, nothing to do.");
		return $self->done(1);
	}

	# Remove any existing BOSH environment variables
	delete @ENV{qw/BOSH_CLIENT BOSH_CLIENT_SECRET BOSH_CA_CERT BOSH_ENVIRONMENT/};
	run($self->bosh->command,'-e', $self->env->name, 'logout');
	my $logged_out = !$self->is_logged_in();
	if (!$logged_out) {
		error("Failed to log out of BOSH director");
		return $self->done(0);
	} else {
		info("Successfully logged out of BOSH director\n");
	}
	return $self->done(1);
}

# }}}

# ssh_to_director - SSH into the BOSH director {{{
sub ssh_to_director {
	my ($self) = @_;

	info("\n#G{Accessing " . $self->env->name . " BOSH director via SSH...}\n");

	# Create temporary key file
	my $key_file = workdir() . "/.ssh_key";
	mkfile_or_fail($key_file, 0600, "");

	# Get private key from vault
	my $private_key = $self->vault->get($ENV{GENESIS_SECRETS_BASE} . "op/net", "private");
	mkfile_or_fail($key_file, 0400, $private_key);

	# Get director host or IP address
	my $ip = $self->_get_host_address();
	# Execute SSH command
	delete $ENV{SSH_AUTH_SOCK};
	system("ssh", "netop\@$ip", "-o", "StrictHostKeyChecking=no", "-i", $key_file);

	return $self->done(1);
}

# }}}

# run_extended_addon - Helper method to delegate to an extended addon {{{
sub run_extended_addon {
	my ($self) = @_;

	# In the original bash script, this would delegate to another addon script
	# For now, we'll just report that the addon wasn't found
	bail("Unknown addon script: $self->{script}");
}

# }}}

# bosh - Get the BOSH director target {{{
sub bosh {
	my ($self) = @_;
	return $self->{bosh} //= $self->env->get_target_bosh({self => 1});
}

# }}}

# _get_host_address - Get the BOSH director host address {{{
sub _get_host_address {
	my ($self) = @_;
	my $bosh = $self->bosh;
	return $bosh->{host} if $bosh && $bosh->{host};
	bail("No BOSH host address found for environment: " . $self->env->name);
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
