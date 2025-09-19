package Genesis::Hook::Info::BOSH v4.0.5;

use v5.20; # Genesis min perl version is 5.20
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail info run warning error/;

# init - Initialize the hook {{{
sub init {
	my ($class, %ops) = @_;
	my $obj = $class->SUPER::init(%ops);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
	return $obj;
}

# }}}

# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;

	# Display access instructions
	my $call_with_env = $self->env->get_call_path_with_env();

	# Gather the necessary information from Exodus
	my %needed_exodus_data = map {($_, $self->exodus_data->{$_}//undef)} qw(
		url
		admin_username
		admin_password
		ca_cert
		credhub_url
		has_vault_credhub_proxy
	);
	$needed_exodus_data{has_vault_credhub_proxy} //= 0;

	my @missing_exodus_fields = grep {!defined($needed_exodus_data{$_})} keys %needed_exodus_data;
	warning(
		"\nMissing the following data from the last deploy:\n%s\n\n".
		"Please redeploy in order to generate the necessary information.\n",
		join("\n", map { "[[  - >>$_" } @missing_exodus_fields)
	) if @missing_exodus_fields;

	my %info = %needed_exodus_data;

	# Display BOSH environment
	info("#Bu{BOSH Director Information}\n");
	my $bosh = $self->env->get_target_bosh({self => 1});
	my ($out, $rc, $err) = $bosh->execute('env', '--tty');
	if ($rc) {
		error(
			"\nFailed to get BOSH environment information:\n%s\n".
			"Please check your BOSH CLI installation and try again.\n",
			join("\n",$out,$err)
		);
	} else {
		info($out =~ s/.*?\n\n//rms =~ s/Succeeded//r);
	}

	info(
		"BOSH Director endpoint information\n".
		"[[  >>#C{%s}\n\n".
		"BOSH Director credentials\n".
		"[[  >>username: #M{%s}\n".
		"[[  >>password: #G{%s}\n\n".
		"BOSH Director CA Certificate:\n".
		"#C{%s}\n\n".
		"To log into the BOSH director from the command line:\n".
		"[[  >>#G{%s do login}\n\n".
		"[[#Yiu{Note:} >>While the above method will allow you to log into the ".
		"BOSH director, it is recommended to use #G{%s bosh <cmd> <options and ".
		"arguments>}.  Doing so will allow you to easily switch between BOSH ".
		"directors, and will automatically set the BOSH environment, and ".
		"in the case of a non-BOSH environment (ie cf, vault, jumpbox), the ".
		"deployment as well.  See #G{%s bosh --help} for details.\n",
		$info{url}            // '}#R{<unknown>',
		$info{admin_username} // '}#R{<unknown>',
		$info{admin_password} // '}#R{<unknown>',
		$info{ca_cert},
		($call_with_env) x 3
	);

	# Check for Credhub
	if ($info{credhub_url}) {
		info(
			"\nTo log into the Credhub provided by this BOSH deployment:\n".
			"[[  >>#G{%s do credhub-login}\n\n".
			"[[#Yiu{Note:} >>Likewise with logging into the BOSH director, ".
			"you can use #G{%s credhub <cmd> <options and arguments>} to ".
			"interact with the Credhub, and it will automatically set the ".
			"credhub base path to the current environment, so rather than ".
			"logging into the Credhub on the BOSH environment, you can ".
			"call Credhub commands on the desired environment (ie cf) and ".
			"it will automatically get the credentials from the Credhub ".
			"on the BOSH director that deployed it.\n",
			($call_with_env) x 2
		);
	}

	# Check for vault-credhub-proxy
	if ($info{has_vault_credhub_proxy}) {
		info(
			"\nTo log into the Credhub via #C{safe} using the vault-credhub-proxy:\n".
			"[[  >>#G{%s do vault-proxy-login}\n\n".
			"This will set up your ~/.saferc file to use the vault-credhub-proxy as ".
			"a vault server, and will allow you to use the #C{safe} command ".
			"to interact with the Credhub on the BOSH director.\n",
			$call_with_env
		);
	}

	return $self->done();
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
