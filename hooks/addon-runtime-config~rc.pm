#!/usr/bin/env perl
package Genesis::Hook::Addon::BOSH::RuntimeConfig v3.3.0;

use strict;
use warnings;

# Only needed for development
my $lib;
BEGIN {$lib = $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use lib $lib;

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info warning success pretty_duration run compare_arrays read_json_from mkfile_or_fail count_nouns/;
use Genesis::UI qw/prompt_for_boolean/;
use Genesis::Term qw/wrap terminal_width render_markdown decolorize bullet/;
use Time::HiRes qw/gettimeofday/;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.20');

	my @builds = qw/dns ops-access/;
	$obj->{args} //= [];
	my $opts = $obj->parse_options([
		'dry-run|n',
		'yes|y',
		'remove|R',
	]);
	for my $opt (keys %$opts) {
		my $key = $opt =~ s/-//rg;
		$obj->{$key} = $opts->{$opt};
	}

	if ($obj->{args}->@*) {
		(undef, $obj->{builds}, my $invalid_builds) = compare_arrays(
			\@builds, $obj->{args}
		);
		bail(
			"Invalid runtime config(s): %s - valid values are: %s",
			join(", ", @$invalid_builds),
			join(", ", @builds)
		) if (@$invalid_builds);
	} else {
		$obj->{builds} = \@builds;
	}

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
		"\n".
		"Runtime Configs:\n".
		"[[  #B{dns}        >>Generate and upload the BOSH DNS runtime config.\n".
		"[[  #B{ops-access} >>Generate and upload the Ops Access runtime config.\n".
		"\n".
		"By default, all of the above runtime configs are generated and uploaded.\n"
}

sub perform {
	my $self = shift;
	my $env = $self->env;
	my ($bosh, $target) = $env->get_target_bosh({self => 1});
	my $vault = $bosh->{exodus_vault}//$env->vault;
	my $credhub = Service::Credhub->from_bosh($bosh, vault => $vault);
	$self->@{qw{bosh credhub vault}} = ($bosh, $credhub, $vault);

	$self->{secrets} = {};
	$self->{credhub_base} = ($credhub->base) 
		if $env->feature_compatibility('3.0.0-rc.1')
		&& scalar($env->lookup('genesis.entomb', 1));


	$ENV{BOSH_NON_INTERACTIVE} = 1 if $self->{yes};

	$env->notify(
		"%s runtime config(s): %s %s", 
		$self->{remove} ? "removing" : "generating",
		join(", ", $self->{builds}->@*),
		$self->{dryrun} ? " (dry-run)" : ""
	);

	return $self->remove_configs() if ($self->{remove});

	for my $config ($self->{builds}->@*) {
		my $build_method = "build_${config}_runtime" =~ s/-/_/gr;
		if ($self->can($build_method)) {
			info({pending => 1}, "  - generating %s runtime config...", $config);
			my $start_time = gettimeofday();
      $self->{secrets_user} = $config;
			my ($config_data,$status,$msg) = $self->$build_method();
      delete $self->{secrets_user};
			if ($status && $status eq 'failed') {
				info("#R{failed}".pretty_duration(gettimeofday() - $start_time));
				error($msg);
				delete $self->{secrets}{$config};
				next;
			} else {
				info("#G{done}".pretty_duration(gettimeofday() - $start_time));
			}
			if ($status && $status eq 'skipped') {
				info("  - skipping %s runtime config generation: %s", $config, $msg);
				next;
			}
			my $config_name = $env->bosh_config_name.".$config";
			if ($self->{dryrun}) {
				info(
					"[[  - >>would upload the following content to #m{%s} runtime config:\n\n%s",
					$config_name,
					render_markdown("```yaml\n$config_data\n```")
				);
			} elsif ($self->{yes}) {
				$start_time = gettimeofday();
				info({pending => 1}, "[[  - >>uploading %s runtime config...", $config);
				$self->{bosh}->upload_config($config_data, 'runtime', $config_name);
				info("#G{done}".pretty_duration(gettimeofday() - $start_time));
			} else  {
				# TODO: Do we need to show a diff here?
				info("[[  - >>uploading %s runtime config:", $config);
				my ($out, $rc) = $self->{bosh}->upload_config($config_data, 'runtime', $config_name, 'confirm');
				if ($rc) {
					if (decolorize($out) =~ /Continue\? \[yN\]: .*Stopped/s) {
						info("[[  - >>#y{skipped}\n");
					} else {
						info("[[  - >>#R{error encountered}\n");
					}
					delete $self->{secrets}{$config};
					next;
				}
				info("  - #G{runtime config upload complete}\n");
			}
		} else {
			bail("Unknown runtime config type: %s", $config);
		}
	}

	# Entombify the secrets if allowed
	my %secrets = map {%$_} values $self->{secrets}->%*;
	if (keys %secrets) {
		my $start_time = gettimeofday();
		# TODO: Might be faster to get the list of existing secrets under
		# /runtime-configs/genesis-entombments and only entomb the new ones (and
		# identify the ones that are already entombed), but right now it only takes
		# ~1-2 seconds, so not a big deal.
		if ($self->{dryrun}) {
			info(
				"[[  - >>would entomb %s used by these runtime configs:\n%s",
				count_nouns( scalar keys %{$self->{secrets}}, "secret"),
				join("\n", map {bullet($_, indent => 4)} map {sprintf(
					"#c{%s}#C{%s}", ($_ =~ m#^(.*/)([^/]+)$#),
				)} sort keys %{$self->{secrets}})
			);
		} else {
			info(
				"[[  - >>entombing %s secrets used by these runtime configs:",
				scalar keys %secrets
			);
			my $idx = 0;
			my $secrets_count = scalar keys %secrets;
			my $w = length("$secrets_count");
			my $previous_lines = 0;
			for my $credhub_var (sort keys %secrets) {
				my $value = $secrets{$credhub_var};
				info( "%s#c{%s}#C{%s}", bullet('', indent => 4),
					($credhub_var =~ m#^(.*/)([^/]+)$#),
				);
				$self->{credhub}->set($credhub_var, $value);
			}
			info("    #G{done}".pretty_duration(gettimeofday() - $start_time));
		}
	}

	# Clean up?
	success("\nDone!\n");

	return $self->done();
}

sub build_dns_runtime {
	my ($self) = @_;

	my $runtime = {
		addons => [
			{
				name => 'bosh-dns',
				include => {
					stemcell => [
						{os => 'ubuntu-xenial'},
						{os => 'ubuntu-bionic'},
						{os => 'ubuntu-jammy'} ] },
				jobs => [
					{
						name => 'bosh-dns',
						release => 'bosh-dns',
						properties => {
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
							} } } ] } ]
	};
	my $whitelist = $self->env->lookup('dns_deployments_whitelist', []);
	if (@$whitelist) {
		push @{$runtime->{addons}[0]{include}{deployments}}, map { {name => $_} } @$whitelist;
	}
	my $blacklist = $self->env->lookup('dns_deployments_blacklist', []);
	my $ig_blacklist = $self->env->lookup('dns_instance_groups_blacklist', []);
	if (@$blacklist || @$ig_blacklist) {
		$runtime->{addons}[0]{exclude} = {};
		$runtime->{addons}[0]{exclude}{deployments} = [map { {name => $_} } @$blacklist] if @$blacklist;
		$runtime->{addons}[0]{exclude}{instance_groups} = [map { {name => $_} } @$ig_blacklist] if @$ig_blacklist;
	}
	if ($self->want_feature('bosh-dns-healthcheck')) {
		$runtime->{addons}[0]{jobs}[0]{properties}{health} = {
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
		};
	}
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

sub remove_configs {
	my ($self) = @_;

	my %existing = map {
		($_->{name} => {
			since => $_->{created_at},
			id => $_->{id} =~ s/\*$//r,
			used => $_->{id} =~ /\*$/
		})
	} @{$self->_get_runtime_configs()};

	my @configs = map {$self->env->bosh_config_name.".".$_} $self->{builds}->@*;
	for my $config (@configs) {
		if (!exists $existing{$config}) {
			info("  - runtime config #g{%s} does not exist", $config);
			next;
		}
		if ($self->{dryrun}) {
			info(
				"[[  - >>would remove %s runtime config #c{%s} (id: %s - %s)",
				$existing{$config}{used} ? "#y{actve}" : "#g{unused}",
				$config, $existing{$config}{id}, $existing{$config}{since}
			);
		} elsif ($self->{yes}) {
			my $start_time = gettimeofday();
			info({pending => 1}, "  - removing existing #g{%s} runtime...", $config);
			$self->{bosh}->delete_config('runtime', $config);
			info("#G{done}".pretty_duration(gettimeofday() - $start_time));
		} else {
      my $prompt = wrap(sprintf(
        "[[  - >>remove %s runtime config #c{%s} (id: %s - %s)? [y|n]",
        $existing{$config}{used} ? "#y{actve}" : "#g{unused}",
        $config, $existing{$config}{id}, $existing{$config}{since}
      ), terminal_width - 2);
			if (prompt_for_boolean($prompt, 0, 1)) {
				info("[[  - >>#y{skipping}\n");
				next;
			}
			$self->{bosh}->delete_config('runtime', $config);
		}
	}

	success("\nruntime config removal complete\n");
	return 1;
}


sub _get_secret {
	my ($self, $secret) = @_;
	my $config = $self->{secrets_user};
	my ($path, $key) = split(/:/, $secret, 2);
	my $original_path = $path;
	my $base_path = $self->env->secrets_store->base;
	$path = $base_path.$path unless $path =~ m#^/#;
	my $value = $self->vault->get($path,$key);
	return $value unless $self->{credhub_base};

	$original_path = "_$original_path" if $original_path =~ m#^/#;
	my $credhub_var = $self->get_credhub_variable(
		$self->{credhub_base}.'runtime-configs/genesis-entombments/',
		$original_path,
		$key,
		$value
	);
	$self->{secrets}{$config//''}{$credhub_var} = $value;
	return "(($credhub_var))";
}

sub _get_runtime_configs {
	my ($self, $name) = @_;
	my @cmd = ('configs', '--type=runtime', '--json');
	push @cmd, '--name='.$name if $name;
	my ($data, $rc, $err) = read_json_from($self->{bosh}->execute(@cmd));
	bail("Failed to get runtime configs: %s", $err) if $rc;
	return $data->{Tables}[0]{Rows};
}

1;
#vim: fdm=marker:foldlevel=1:noet
