package Genesis::Hook::Addon::BOSH::Resurrection v3.3.0;

use v5.20;    # Genesis min perl version is 5.20
use warnings;

# Only needed for development
BEGIN { push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME} . '/.genesis/lib' }

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail error info debug run in_array mkfile_or_fail/;

# init - Initialize the hook {{{
sub init {
	my $class = shift;
	my $obj   = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
	return $obj;
}

# }}}
# cmd_details - Documentation that is shown when running with --help {{{
sub cmd_details {
	return "Checks or sets bosh resurrection state. Set state with truthy or falsey " .
	  "arguments (ie: yes|no, true|false, on|off, enabled|disabled)\n" . "\n" .
	  "With no argument, displays state if BOSH director is tracking " .
	  "the state; otherwise, reports state at last deployment.\n" . "\n" .
	  "Note: This currently does not reflect resurrection config effects.\n" . "\n" .
	  "Limitation: Database access is limited to internal PostgreSQL database.\n" .
	  "External PostgreSQL and MySQL may be supported in the future (PRs welcome)";
}

# }}}
# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;
	my $env    = $self->env;
	my $args   = $self->{args} || [];
	my $bosh   = $env->get_target_bosh( { self => 1 } );

	# Process the command line arguments
	if (@$args) {
		my $state;

		# Parse state argument
		# FIXME: See if we can use Genesis::env::set : return if env set for the 1|yes|t... stuff
		my $arg = $args->[0];
		if ( $arg =~ /^(1|y|yes|t|true|on|enable.*)$/i ) {    # check for explicit true
			$state = "on";
		}
		elsif ( $arg =~ /^(0|n|no|f|false|off|disable.*)$/i ) {    # check for explicit false
			$state = "off";
		}
		else {
			bail(
"Expecting one of the following arguments: on (aka: yes|true|enabled|1) or off (aka: no|false|disabled|0)"
			);
		}

		# Update resurrection state
		my ( $out, $rc, $err ) = $bosh->execute( "update-resurrection", $state );
		bail( "Failed to set resurrection state: %s", $err ) if $rc;
		info( "\nResurrection on #M{%s} is now set to %s\n",
			$env->name, $state eq 'on' ? "#G{on}" : "#R{off}" );
		return $self->done();
	}

	# Get BOSH director IP
	my $host = $self->exodus_data->{url} =~ s{^https?://}{}r =~ s{:[0-9]+$}{}r;
	info("Target BOSH director located at $host");

	# Determine if the environment has netop user active
	my $has_netop = !in_array( 'skip-ops-users', $self->features );

	my @ssh_cmd;
	my $key_file;

	if ($has_netop) {

		# Set up SSH with netop user
		$key_file = $env->workpath(".key");

		## can be done with make file or fail
		mkfile_or_fail( $key_file, 0600,
			$self->vault->get( $env->secrets_base . "op/net:private" ) );

		@ssh_cmd = ( "ssh", "netop\@$host", "-o", "StrictHostKeyChecking=no", "-i", $key_file );
	}
	elsif ( $env->use_create_env ) {

		# If create-env and no netop user, we can't proceed
		bail( "Cannot connect to %s using netop user -- skip-op-users feature is enabled",
			$env->name );
	}
	else {
		# Do it the slow way via BOSH SSH
		#my $call_with_env = $self->env->get_call_path_with_env();
		# TODO: can we use the above
		@ssh_cmd = (
			$env->get_call_path_with_env,
			"bosh", ( $env->use_create_env ? () : ('--self') ),
			"ssh", "-c"
		);
	}

	# Try to find PostgreSQL client and query resurrection state
	info("Connecting to PostgreSQL database on BOSH director...");

	my $psql;
	my ( $out, $rc ) = run(
		{
			stderr => '/dev/null',
			env    => {
				SSH_AUTH_SOCK => undef,    # Disable SSH agent forwarding
			}
		},
		@ssh_cmd,
'ps auwwx| grep "/packages/[^ ]*/bin/[p]ostgres" | grep "/var/[^ ]*/bin/postgres" | sed -e \'s#.*\\(/var/[^ ]*/bin\\)/postgres.*#\\1/psql#\''
	);

	$psql = $out      if ( $rc == 0 && $out =~ /\S/ );
	$psql =~ s/\s+$// if $psql;

	my $paused = '';

	# FIXME: See if this can be done with get target bosh execute methodology.
	if ($psql) {
		info("Retrieving current resurrection status from database...");
		( $out, $rc ) = run(
			{
				stderr => '/dev/null',
				env    => {
					SSH_AUTH_SOCK => undef,    # Disable SSH agent forwarding
				}
			},
			@ssh_cmd,
			$psql .
' -U vcap -h localhost bosh -t -c "select value from director_attributes where name=\'resurrection_paused\' limit 1" | grep \' \\(true\\|false\\)\' | sed -E \'s/.* (true|false).*/\\1/\''
		);

		$paused = $out      if ( $rc == 0 && $out =~ /^(true|false)$/ );
		$paused =~ s/\s+$// if $paused;
	}
	else {
		info(
"#Y{Warning:} Could not determine Postgres client on BOSH instance -- cannot access database; deferring to last manifest value"
		);
		$paused = 'not-available';
	}

	# Clean up key file if we created one
	unlink $key_file if $key_file && -f $key_file;

	# Determine resurrection state
	my $state;
	if ( $paused eq 'true' ) {
		$state = "#R{off}";
	}
	elsif ( $paused eq 'false' ) {
		$state = "#G{on}";
	}
	else {
		if ( $paused ne 'not-available' ) {
			info(
"#Y{Warning:} Database did not contain resurrection status - checking manifest of last deployment"
			);
		}

		my $deployed_state = $env->last_deployed_lookup(
			"instance_groups[name=bosh].properties.hm.resurrector_enabled");

		if ( $deployed_state eq 'true' ) {
			$state = "#G{on} (based on last deployed manifest)";
		}
		elsif ( $deployed_state eq 'false' ) {
			$state = "#R{off} (based on last deployed manifest)";
		}
		else {
			$state = "#Y{unknown - likely on by default}";
		}
	}

	# Output result
	info( "\nResurrection on #M{%s} is currently %s\n", $env->name, $state );

	return $self->done();
}

# }}}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
