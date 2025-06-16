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

	# Define valid builds
	$obj->register_runtime_config_builds(
		[dns => "BOSH DNS"],
		'ops-access',
		'toolbelt',
	);
	$obj->validate_runtime_config_builds();

	return $obj;
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

sub build_toolbelt_runtime {
	my ($self) = @_;
	return ("","skipped","Feature 'toolbelt' is not enabled") unless $self->want_feature('toolbelt');

	my $toolbelt_runtime = {
		addons => [
			{
				name => 'toolbelt',
				include => {
					stemcell => [
						{os => 'ubuntu-trusty'},
						{os => 'ubuntu-xenial'},
						{os => 'ubuntu-bionic'},
						{os => 'ubuntu-jammy'}
					]
				},
				jobs => [
					{name => 'toolbelt',       release => 'toolbelt'},
					{name => 'toolbelt-quick', release => 'toolbelt'}
				]
			},
			{
				name => 'toolbelt-veritas',
				include => {
					stemcell => [
						{os => 'ubuntu-trusty'},
						{os => 'ubuntu-xenial'},
						{os => 'ubuntu-bionic'},
						{os => 'ubuntu-jammy'}
					],
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

1;
#vim: fdm=marker:foldlevel=1:noet
