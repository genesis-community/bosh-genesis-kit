package Genesis::Hook::RuntimeConfig::BOSH v3.3.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}


use parent qw(Genesis::Hook::RuntimeConfig);

use Genesis qw/bail info warning success pretty_duration run compare_arrays read_json_from mkfile_or_fail count_nouns load_yaml_file/;
use Genesis::UI qw/prompt_for_boolean/;
use Genesis::Term qw/wrap terminal_width render_markdown decolorize bullet/;
use Time::HiRes qw/gettimeofday/;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.20');

	# Define valid builds
	$obj->register_runtime_config_builds(
		[dns => "BOSH DNS"],
		'ops-access',
		'toolbelt',
		'syslog',
	);
	$obj->validate_runtime_config_requests();

	$obj->{default_stemcells} = [qw/
		ubuntu-bionic
		ubuntu-jammy
	/];

	return $obj;
}

sub build_dns_runtime {
	my ($self) = @_;

	# Use the user-provided stemcells, but filter out Windows stemcells
	# FIXME: How do we warn the user that we're ignoring Windows stemcells?
	my $stemcells = $self->{request_options}{dns}{params}{stemcells} // $self->{default_stemcells};

	# There are three different flavors of stemcells we support for BOSH DNS:
	my $clasic_linux_stemcells = [map {{os => $_}} grep {$_ =~ /^ubuntu-(?:trusty|xenial|bionic|focal|jammy)$/} @$stemcells];
	my $systemd_linux_stemcells = [map {{os => $_}} grep {$_ =~ /^ubuntu-(?:noble)$/} @$stemcells];
	my $windows_stemcells = [map {{os => $_}} grep {$_ =~ /^windows(.*)$/} @$stemcells];

	my %job_properties = (
		api => {
			client => {
				tls => {
					ca => $self->_get_secret('dns_api_tls/ca:certificate'),
					certificate => $self->_get_secret('dns_api_tls/client:certificate'),
					private_key => $self->_get_secret('dns_api_tls/client:key') } },
			server => {
				tls => {
					ca => $self->_get_secret('dns_api_tls/ca:certificate'),
					certificate => $self->_get_secret('dns_api_tls/server:certificate'),
					private_key => $self->_get_secret('dns_api_tls/server:key') } }
		},
		cache => {
			enabled => scalar($self->env->lookup('dns_cache', JSON::PP::true))
		}
	);

	$job_properties{health} = {
		enabled => JSON::PP::true,
		client => {
			tls => {
				ca => $self->_get_secret('dns_healthcheck_tls/ca:certificate'),
				certificate => $self->_get_secret('dns_healthcheck_tls/client:certificate'),
				private_key => $self->_get_secret('dns_healthcheck_tls/client:key') } },
		server => {
			tls => {
				ca => $self->_get_secret('dns_healthcheck_tls/ca:certificate'),
				certificate => $self->_get_secret('dns_healthcheck_tls/server:certificate'),
				private_key => $self->_get_secret('dns_healthcheck_tls/server:key') } }
	} if ($self->{request_options}{dns}{params}{enable_healthcheck}//$self->want_feature('bosh-dns-healthcheck'));

	my $included_deployments = {};
	my $whitelist = $self->env->lookup('dns_deployments_whitelist', []);
	$included_deployments->{deployments} = map { {name => $_} } @$whitelist if (@$whitelist);

	my $excludes = {};
	my $blacklist = $self->env->lookup('dns_deployments_blacklist', []);
	$excludes->{deployments} = [map { {name => $_} } @$blacklist] if @$blacklist;
	my $ig_blacklist = $self->env->lookup('dns_instance_groups_blacklist', []);
	$excludes->{instance_groups} = [map { {name => $_} } @$ig_blacklist] if @$ig_blacklist;
	$excludes = keys %$excludes ? {exclude => $excludes} : {};

	my $runtime = {addons => []};
	push @{$runtime->{addons}}, {
		name => 'bosh-dns',
		include => {
			stemcell => $clasic_linux_stemcells,
			%$included_deployments,
		},
		%$excludes,
		jobs => [{
			name => 'bosh-dns',
			release => 'bosh-dns',
			properties => {%job_properties},
		}]
	} if @$clasic_linux_stemcells;
	push @{$runtime->{addons}}, {
		name => 'bosh-dns-systemd',
		include => {
			stemcell => $systemd_linux_stemcells,
			%$included_deployments,
		},
		%$excludes,
		jobs => [{
			name => 'bosh-dns',
			release => 'bosh-dns',
			properties => {
				%job_properties,
				configure_systemd_resolved => JSON::PP::true,
				disable_recursors => JSON::PP::true,
			}
		}]
	} if @$systemd_linux_stemcells;
	push @{$runtime->{addons}}, {
		name => 'bosh-dns-windows',
		include => {
			stemcell => $windows_stemcells,
			%$included_deployments,
		},
		%$excludes,
		jobs => [{
			name => 'bosh-dns',
			release => 'bosh-dns',
			properties => {%job_properties}
		}]
	} if @$windows_stemcells;

	my $upstream_release = scalar($self->spruce_merge(
		'--skip-eval',
		'--cherry-pick',
		'releases',
		$self->kit->path('bosh-deployment/runtime-configs/dns.yml')
	));

	my ($out, $rc, $err) = run(
		'spruce merge <(echo "$1") <(echo "$2") $3',
		JSON::PP::encode_json($runtime),
		$upstream_release,
		$self->kit->path('overlay/releases/bosh-dns.yml')
	);
	bail("Failed to merge DNS runtime: %s", $err) if $rc;

	return $out;
}

sub build_ops_access_runtime {
	my ($self, %opts) = @_;
	return ("","skipped","Features 'ocfp, 'netop-access' and/or 'sysop-access' are not enabled")
		unless grep { $_ =~ /^((net|sys)op-access|ocfp)$/ } $self->features;

	# This runtime config doesn't filter on stemcells, so that option is ignored.

	my $ops_access_runtime = {
		addons => [
			{
				name => 'genesis-local-users',
				exclude => {
					jobs => [
						{name => 'user_add', release => 'os-conf'}
					]
				},
				jobs => [
					{
						name => 'user_add',
						release => 'os-conf',
						properties => {
							persistent_homes => JSON::PP::true,
							users => []
						}
					}
				]
			}
		]
	};

	if ($self->want_feature('netop-access') || $self->want_feature('ocfp')) {
		push @{$ops_access_runtime->{addons}[0]{jobs}[0]{properties}{users}}, {
			name => 'netop',
			public_key => $self->_get_secret('op/net:public')
		};
	}
	if ($self->want_feature('sysop-access')) {
		push @{$ops_access_runtime->{addons}[0]{jobs}[0]{properties}{users}}, {
			name => 'sysop',
			crypted_password => $self->_get_secret('op/sys:password-crypt-sha512')
		};
	};
	my ($out, $rc, $err) = run(
		'spruce merge <(echo "$1") $2',
		JSON::PP::encode_json($ops_access_runtime),
		$self->kit->path('overlay/releases/os-conf.yml')
	);
	bail("Failed to merge ops-access runtime: %s", $err) if $rc;
	return $out;
}

sub build_toolbelt_runtime {
	my ($self) = @_;
	return ("","skipped","Feature 'toolbelt' is not enabled")
		unless $self->want_feature('toolbelt') || $self->want_feature('ocfp');

	# Use the user-proided stemcells, but filter out Windows stemcells
	# FIXME: How do we warn the user that we're ignoring Windows stemcells?
	my $stemcells = $self->{request_options}{toolbelt}{params}{stemcells} // $self->{default_stemcells};
	my $stemcell_filter = [map {{os => $_}} grep {$_ !~ /^windows/} @$stemcells];

	my $toolbelt_runtime = {
		addons => [
			{
				name => 'toolbelt',
				include => {
					stemcell => $stemcell_filter,
				},
				jobs => [
					{name => 'toolbelt',       release => 'toolbelt'},
					{name => 'toolbelt-quick', release => 'toolbelt'}
				]
			},
			{
				name => 'toolbelt-veritas',
				include => {
					stemcell => $stemcell_filter,
					jobs => [
						{name => 'bbs',        release => 'diego'},
						{name => 'rep',        release => 'diego'},
						{name => 'auctioneer', release => 'diego'}
					]
				},
				jobs => [
					{name => 'toolbelt-veritas', release => 'toolbelt'}
				]
			}
		]
	};

	my ($out, $rc, $err) = run(
		'spruce merge <(echo "$1") $2',
		JSON::PP::encode_json($toolbelt_runtime),
		$self->kit->path('overlay/releases/toolbelt.yml')
	);
	bail("Failed to merge toolbelt runtime: %s", $err) if $rc;
	return $out;
}

sub build_syslog_runtime {
	my ($self) = @_;

	# Check if the syslog hostname and port are defined
	my $syslog = $self->env->vault->get($self->env->secrets_mount.'syslog');
	return (
		"","skipped","'syslog' runtime not created - missing 'hostname' or 'port' in vault"
	) unless $syslog->{hostname} && $syslog->{port};

	my $stemcells = $self->{request_options}{syslog}{params}{stemcells} // $self->{default_stemcells};
	my @ubuntu_stemcells = map {{os => $_}} grep {/^ubuntu/} @$stemcells;
	my @windows_stemcells = map {{os => $_}} grep {/^windows/} @$stemcells;

	my $release = $self->env->manifest_lookup('releases.syslog', undef);
	if (!$release && -e $self->kit->path('overlay/releases/syslog.yml')) {
		$release = load_yaml_file(
			$self->kit->path('overlay/releases/syslog.yml')
		)->{releases}{syslog};
	}
	if (!$release || !$release->{name}) {
		# Fallback to the upstream syslog release if not defined in the kit
		my $patch = load_yaml_file(
			$self->kit->path('bosh-deployment/syslog.yml')
		);
		# This is a go-patch file, so we must extract it
		$release = (grep {$_->{release} eq 'syslog'} @{$patch->{releases}})[0]->{value};
		if (!$release) {
			bail("Failed to find syslog release in the environment, kit or upstream syslog.yml");
		}
	}
	my $properties = {
		address   => $syslog->{hostname},
		port      => $syslog->{port},
		transport => $syslog->{protocol} // 'tcp',
		respect_file_permissions => JSON::PP::false,
	};
	if ($self->env->vault->has($self->env->secrets_mount.'certs/org', 'ca_full')) {
		# Generate the entombed CA cert reference - RuntimeConfig will
		# automatically entomb the vault secret.
		$properties->{ca_cert} = $self->_get_secret(
			$self->env->secrets_mount.'certs/org:ca_full'
		);
		$properties->{tls_enabled} = JSON::PP::true;
	}

	my $runtime = {
		addons => [
			{
				name => 'syslog',
				include => {
					stemcell => \@ubuntu_stemcells,
				},
				exclude => {
					instance_groups => [ 'smoke-tests' ],
					lifecycle => 'errand'
				},
				jobs => [
					{
						name => 'syslog_forwarder',
						release => 'syslog',
						properties => {
							syslog => $properties
						}
					}
				]
			}
		],
		releases => [$release]
	};

	if (@windows_stemcells) {
		# If there are Windows stemcells, we need to add the windows-syslog
		# release and job to the runtime config.
		my $windows_release = $self->env->manifest_lookup('releases.windows-syslog', undef);
		if (!$windows_release && -e $self->kit->path('overlay/releases/windows-syslog.yml')) {
			$windows_release = load_yaml_file(
				$self->kit->path('overlay/releases/windows-syslog.yml')
			)->{releases}{'windows-syslog'};
		}
		bail(
			"No windows-syslog release defined in the environment, kit or upstream syslog.yml"
		) unless $windows_release && $windows_release->{name};


		push @{$runtime->{addons}}, {
			name => 'windows-syslog',
			include => {
				stemcell => \@windows_stemcells,
			},
			exclude => {
				lifecycle => 'errand'
			},
			jobs => [
				{
					name => 'syslog_forwarder_windows',
					release => 'windows-syslog',
					properties => {
						syslog => $properties,
					}
				}
			]
		};
		push @{$runtime->{releases}}, $windows_release;
	}

	my ($out, $rc, $err) = run(
		'spruce merge <(echo "$1")',
		JSON::PP::encode_json($runtime),
	);

	bail("Failed to merge toolbelt runtime: %s", $err) if $rc;
	return $out;
}


1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
