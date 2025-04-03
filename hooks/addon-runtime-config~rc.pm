#!/usr/bin/env perl
package Genesis::Hook::Addon::BOSH::RuntimeConfig v3.3.0;

use strict;
use warnings;

# Only needed for development
my $lib;
BEGIN {$lib = $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use lib $lib;

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info warning error in_array new_enough time_exec mkfile_or_fail pretty_duration run/;
use Genesis::Term qw/terminal_width render_markdown decolorize/;
use JSON::PP;

# Give us the bosh and credhub functions that target this director instead of
# parent director
require File::Basename; require Cwd;
require(File::Basename::dirname(Cwd::abs_path(__FILE__)).'/lib/BoshDirectorAccess.pm');
BoshDirectorAccess->import();

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
	return $obj;
}

sub cmd_details {
	return 
		"Generate the runtime config, and upload it to the target BOSH director\n".
		"\n".
		"Options:\n".
		"[[  #y{-n}      >>Dry run, just print out the runtime config without ".
		                  "uploading it.\n".
		"[[  #y{-y}      >>Upload changes without prompting for confirmation.\n".
		"[[  #y{-R}      >>Remove the runtime config from the director instead.\n".
		"[[  #y{-d}      >>Upload the config to the default runtime config, ".
		                  "merging with what is currently there.  This is not ".
		                  "recommended, but included for backwards compatibility."
}

sub perform {
	my $self = shift;
	my $env = $self->env;

	# Parse options
	my %opts = $self->parse_options([
		'dry-run|n',
		'yes|y',
		'remove|R',
		'default|d'
	]);
	bail(
		"No arguments expected: %s",
		join(" ", @{$self->{args}||[]})
	) if @{$self->{args}||[]};

	$ENV{BOSH_NON_INTERACTIVE} = 1 if $opts{yes};
	# TODO: Add Clean up entombed secrets option

	my %existing = map {
		($_->{name} => {
			since => $_->{created_at},
			id => $_->{id} =~ s/\*$//r,
			used => $_->{id} =~ /\*$/
		})
	} @{$self->_get_runtime_configs()};

	$env->notify(
		"%s runtime config%s", 
		$opts{removal} ? "removing" : "generating",
		$opts{'dry-run'} ? " (dry-run)" : ""
	);

	if ($opts{removal}) {
		my @configs = $opts{default}
			? ('default')
			: ('genesis.bosh-dns', 'genesis.ops-access');
		for my $config (@configs) {
			if (!exists $existing{$config}) {
				info("  - runtime config #g{%s} does not exist", $config);
				next;
			}
			if ($opts{'dry-run'}) {
				info(
					"[[  - >>would remove %s runtime config #c{%s} (id: %s - %s)",
					$existing{$config}{used} ? "#y{actve}" : "#g{unused}",
					$config, $existing{$config}{id}, $existing{$config}{since}
				);
			} else {
				my $start_time = time();
				info({pending => 1}, "  - removing existing #g{%s} runtime...", $config);
				my ($out,$rc,$err) = $self->_remove_runtime_config($config);
				if ($rc) {
					info("#R{failed}");
					bail("Failed to remove runtime config: %s", $err);
				} else {
					info("#G{done}".pretty_duration(time() - $start_time));
				}
				info("#G{done}".pretty_duration(time() - $start_time));
			}
		}
		info($opts{'dry-run'} ? "" : "  - runtime config removal complete\n");
		return 1;
	}


	info({pending => 1}, "  - gathering current Exodus metadata...");
	my %exodus;
	my $t = time_exec(sub {
		%exodus = %{$self->exodus_data()};
	});
	unless (keys %exodus) {
		info("#R{failed}");
		bail(
			"Environment '#C{%s}' has not been deployed.  Please deploy it first, ".
			"then rerun the 'runtime-config' addon",
			$env->name
		);
	}
	info("#G{done}".pretty_duration($t, 0.5, 1.0));

	# Determine secrets to be used, ensure they exist, and entomb them if necessary
	info({pending => 1},"[[  - >>looking up secrets for runtime config...");
	my $start_time = time();
	my @secrets =  qw(
		dns_api_tls/ca:certificate
		dns_api_tls/client:certificate
		dns_api_tls/client:key
		dns_api_tls/server:certificate
		dns_api_tls/server:key
	);
	push @secrets, qw(
		dns_healthcheck_tls/ca:certificate
		dns_healthcheck_tls/client:certificate
		dns_healthcheck_tls/client:key
		dns_healthcheck_tls/server:certificate
		dns_healthcheck_tls/server:key
	) if ($self->want_feature('bosh-dns-healthcheck'));
	push @secrets, 'op/net:public'
		if ($self->want_feature('netop-access'));
	push @secrets, 'op/sys:password-crypt-sha512'
		if ($self->want_feature('sysop-access'));

	my $secret_values = $env->secrets_store->store_data();
	info("#G{done}".pretty_duration(time() - $start_time));
	my $base_path = $env->secrets_store->base =~ s/^\///r;
	my @missing_secrets = ();
	for my $secret (@secrets) {
		my ($path, $key) = split(/:/, $secret, 2);
		if (!exists $secret_values->{$base_path.$path} || !exists $secret_values->{$base_path.$path}{$key}) {
			push @missing_secrets, $secret;
		}
	}
	bail("Missing secrets: %s", join(", ", @missing_secrets)) if @missing_secrets;

	# Entombify the secrets if allowed - TODO: extract this to a helper
	my $vault = $env->secrets_store->service;
	if ($env->can_be_entombed) {
		do $ENV{GENESIS_LIB}."/Genesis/Env/Manifest/_entombment_mixin.pm";
		$vault = $self->_setup_local_vault();
		my $credhub = $self->credhub();
		$start_time = time();
		info("[[  - >>entombifying %s secrets...", scalar @secrets);
		my $idx = 0;
		my $secrets_count = scalar @secrets;
		my $w = length("$secrets_count");
		my $previous_lines = 0;
		for my $secret (sort @secrets) {
			my ($path, $key) = split(/:/, $secret, 2);
			my $value = $secret_values->{$base_path.$path}{$key};
			my ($credhub_var, $secret_sha, $action, $action_color, $existing) = $self->_entomb_secret(
				$vault, $base_path.$path, $key, $value, $credhub, $path, "/runtime-config/genesis-entombed/"
			);
			my $msg = wrap(sprintf(
				"[[    [%*d/%*d] >>%s:#c{%s} #Kk{[sha1: }#Wk{%s}#Kk{]} #G{=>} #B{%s} ...#%s{%s}",
				$w, ++$idx, $w, $secrets_count, "#C{$path}", $key, $secret_sha,
				$credhub_var, $action_color, $action
			), terminal_width);
			print STDERR "\r[A[2K" for (1..$previous_lines);
			info $msg;
			$previous_lines=($existing && $existing eq $value) ? scalar(lines($msg)) : 0;
		}
		print STDERR "\r[A[2K" for (1..$previous_lines);
		info("  - finished entombifying %s secrets%s", $secrets_count, pretty_duration(time() - $start_time));
	}

	# Generate the runtime config
	$self->{vault} = $vault;
	if($opts{'dry-run'}) {
		if ($opts{default}) {
			my $config = $self->_generate_merged_default_runtime();
			info("[[  - >>would upload #c{default} runtime config:");
			info("\n".render_markdown("```yaml\n$config\n```"));
		} else {
			my $dns_config = $self->_generate_dns_runtime();
			info("[[  - >>would upload #c{genesis.bosh-dns} runtime config:");
			info("\n".render_markdown("```yaml\n$dns_config\n```"));
			if ($self->want_feature('netop-access') || $self->want_feature('sysop-access')) {
				my $ops_config = $self->_generate_ops_access_runtime();
				info("[[  - >>would upload #c{genesis.ops-access} runtime config:");
				info("\n".render_markdown("```yaml\n$ops_config\n```"));
			}
		}
	} else {
		if ($opts{default}) {
			my $config = $self->_generate_merged_default_runtime();
			info("[[  - >>upload #c{default} runtime config:\n");
			$self->_upload_runtime_config('default', $config);
		} else {
			my $dns_config = $self->_generate_dns_runtime();
			info("[[  - >>upload #c{genesis.bosh-dns} runtime config:\n");
			$self->_upload_runtime_config('genesis.bosh-dns', $dns_config);
			if ($self->want_feature('netop-access') || $self->want_feature('sysop-access')) {
				my $ops_config = $self->_generate_ops_access_runtime();
				info("[[  - >>upload #c{genesis.ops-access} runtime config:\n");
				$self->_upload_runtime_config('genesis.ops-access', $ops_config);
			}
		}
	}

	# FIXME: Clean up outdated entombed secrets if any
	
	# TODO: Set the result (defaults to 1 right now)
	$self->done();
}


sub _get_secret {
	my ($self, $secret) = @_;
	my ($path, $key) = split(/:/, $secret, 2);
	my $base_path = $self->env->secrets_store->base;
	$self->vault->get($base_path.$path,$key);
}

sub _upload_runtime_config {
	my ($self, $name, $contents) = @_;
	my $file = mkfile_or_fail($self->env->workpath('runtime-configs.yml'), $contents);
	my ($out, $rc, $err) = $self->bosh->execute({interactive => 1},
		'update-runtime-config',
		'--tty',
		'--no-redact',
		'--name='.$name,
		$file
	);
	$out = decolorize($out) =~ s/\r//rg; # remove color codes and CRs
	$err = $err 
		? $err 
	: ($rc == 0 && $out =~ /^Succeeded$/m)
		? ""
	: ($out =~ /^Stopped$/m)
		? "Operation stopped by user"
		: "Unknown error";

	if ($rc) {
		if ($err eq "Operation stopped by user") {
			warning("\nDid not upload runtime config: %s\n", $err);
		} else {
			bail("Failed to upload runtime config: %s", $err);
		}
	}
	return $out;
}

sub _get_runtime_config {
	my ($self, $name) = @_;
	my $config = $self->read_json_from_bosh('config', '--type=runtime', '--name='.$name);
	return $config ? $config->[0]{content} : "";
}

sub _remove_runtime_config {
	my ($self, $name) = @_;
	my $config = $self->_get_runtime_configs($name);
	if ($config) {
		info("Removing existing '#C{%s}' runtime:", $name);
		info("  - $_") for split(/\n/, $config);
		info("");
		$self->bosh->execute({interactive => 1}, 'delete-config', '--type=runtime', '--name='.$name);
	}
}

sub _get_runtime_configs {
	$_[0]->read_json_from_bosh('configs', '--type=runtime');
}

sub _generate_dns_runtime {
	my $self = shift;

	my $dns_runtime = {
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
		push @{$dns_runtime->{addons}[0]{include}{deployments}}, map { {name => $_} } @$whitelist;
	}
	my $blacklist = $self->env->lookup('dns_deployments_blacklist', []);
	my $ig_blacklist = $self->env->lookup('dns_instance_groups_blacklist', []);
	if (@$blacklist || @$ig_blacklist) {
		$dns_runtime->{addons}[0]{exclude} = {};
		$dns_runtime->{addons}[0]{exclude}{deployments} = [map { {name => $_} } @$blacklist] if @$blacklist;
		$dns_runtime->{addons}[0]{exclude}{instance_groups} = [map { {name => $_} } @$ig_blacklist] if @$ig_blacklist;
	}
	if ($self->want_feature('bosh-dns-healthcheck')) {
		$dns_runtime->{addons}[0]{jobs}[0]{properties}{health} = {
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
		JSON::PP::encode_json($dns_runtime),
		$upstream_release,
		$self->kit->path('overlay/releases/bosh-dns.yml')
	);
	bail("Failed to merge DNS runtime: %s", $err) if $rc;
	return $out;
}

sub _generate_ops_access_runtime {
	my $self = shift;
	return "" unless grep { $_ =~ /^(net|sys)op-access$/ } $self->features;

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
							users => [
								{
									name => 'netop',
									public_key => $self->_get_secret('op/net:public')
								},
								{
									name => 'sysop',
									crypted_password => $self->_get_secret('op/sys:password-crypt-sha512')
								}
							] } } ] } ]
	};
	my ($out, $rc, $err) = run(
		'spruce merge <(echo "$1") $2',
		JSON::PP::encode_json($ops_access_runtime),
		$self->kit->path('overlay/releases/os-conf.yml')
	);
	bail("Failed to merge ops-access runtime: %s", $err) if $rc;
	return $out;
}

sub _generate_merged_default_runtime {
	my $self = shift;
	my $runtime = {
		addons => [
			{name => 'genesis-local-users'},
			{name => 'bosh-dns'}
		]
	};
	my ($combined, $rc, $err) = run(
		'spruce merge <(echo "$1") <(echo "$2") <(echo "$3")',
		JSON::PP::encode_json($runtime),
		$self->_generate_dns_runtime(),
		$self->_generate_ops_access_runtime(),
	);

	bail("Failed to merge default runtime: %s", $err) if $rc;
	return $combined;
}

1;
#vim: fdm=marker:foldlevel=1:noet
