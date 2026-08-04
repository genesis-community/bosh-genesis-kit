#!/usr/bin/env perl
# Unit tests for the pve CPI property map in hooks/cpi-config.pm.
#
# hooks/cpi-config.pm only runs for OCFP environments, and spec/spec.t has
# no ocfp env: the ocfp feature needs bloc config in vault
# (secret/config/<bloc>/...) and a live create-env, neither of which the
# validator sandbox provides (see the NOTE in spec/spec.t). So none of
# spec/deployments/pve*.yml exercise this hook at all, and the pve map's
# emitted property *names* were never checked against jobs/pve_cpi/spec.
# They did not match: every entry emitted a flat name (pve_host) where the
# job declares a nested one (pve.host), so nothing the map produced was
# ever read by jobs/pve_cpi/templates/cpi.json.erb.
#
# This file loads the real hook module directly and drives
# gather_properties_for_pve against thin test doubles for the env-side
# collaborators, so the code under test -- the kit's _property_map_for_pve
# and gather_properties_for_pve, plus the base class's gather_properties
# parse/lookup/entomb/override/unflatten pipeline -- runs unmodified.
#
# Required cases:
#   (a) every mapped property lands at the path jobs/pve_cpi/spec declares,
#       and nothing is left at the top level under its env-yml key.
#   (b) `!` secrets are entombed and appear ONLY as a credhub reference.
#       This is the regression that makes the >path change unsafe on its
#       own: gather_properties' manual-override pass keys off the source
#       key while the config hash is keyed by output path, so once they
#       diverge the raw secret is copied back in beside its own reference.
#   (c) a spruce operator in a mapped key never reaches the top level. The
#       cpi-config is uploaded unevaluated, and the director parses a bare
#       (( ... )) as a BOSH variable reference, failing every deployment
#       against it.
#   (d) keys the map does NOT model still pass through, because that is
#       what the override pass is for.
use strict;
use warnings;
use FindBin;
use Test::More;

my $hook_file = "$FindBin::Bin/../../hooks/cpi-config.pm";
require $hook_file;

# --- Test doubles ------------------------------------------------------

package Test::FakeEnv;

sub new {
	my ($class, %opts) = @_;
	return bless { data => $opts{data} // {} }, $class;
}

# Minimal stand-in for Genesis::Env::lookup. gather_properties calls this in
# list context and treats the second element as "found", so the found flag
# has to be real: returning a bare undef value would send every lookup down
# the ocfp_config_lookup fallback instead.
sub lookup {
	my ($self, $key, $default) = @_;
	my @path = split /\./, $key;
	my $node = $self->{data};
	for my $seg (@path) {
		return (wantarray ? ($default, 0) : $default)
			unless ref($node) eq 'HASH' && exists $node->{$seg};
		$node = $node->{$seg};
	}
	return wantarray ? ($node, 1) : $node;
}

# The env yml is not spruce-evaluated here, which matches the real
# lookup_unevaled: the override pass deliberately reads raw values.
sub lookup_unevaled {
	my ($self, $key) = @_;
	return $self->lookup($key, {});
}

# No OCFP bloc config in the sandbox; every lookup falls through to the
# map's declared default.
sub ocfp_config_lookup { return (undef, 0) }

sub cpi_credhub_base { '/cpi-config/properties/' }

package Test::FakeCpiConfig;

# Inherit the real hook module under test -- _property_map_for_pve and
# gather_properties_for_pve are NOT overridden here, so they run as
# shipped. Only the env-side collaborators are stubbed.
our @ISA = ('Genesis::Hook::CpiConfig::BOSH');

sub new {
	my ($class, %opts) = @_;
	return bless {
		env             => $opts{env},
		credhub_secrets => {},
	}, $class;
}

sub env  { $_[0]->{env} }
sub iaas { 'pve' }

package main;

# The bosh-configs.cpi block an operator actually writes: flat pve_* keys.
sub build_hook {
	my (%cpi) = @_;
	my $env = Test::FakeEnv->new(
		data => { 'bosh-configs' => { cpi => \%cpi } },
	);
	return Test::FakeCpiConfig->new(env => $env);
}

my %BASE_CPI = (
	pve_host           => '10.115.16.1',
	pve_user           => 'ocfp-cpi@pve',
	pve_node           => 'lab-pipes-0',
	pve_vm_storage     => 'local-lvm-data',
	pve_disk_storage   => 'local-lvm-data',
	pve_network_bridge => 'ocfp',
	pve_verify_ssl     => 0,
	pve_agent_mbus     => 'nats://10.115.16.4:4222',
);

# Property names as declared in jobs/pve_cpi/spec of bosh-pve-cpi-release,
# and read back by jobs/pve_cpi/templates/cpi.json.erb via p("pve.host"),
# p("pve.node"), ... and if_p("agent.mbus"). Nothing the map emits is read
# by the job unless it arrives at one of these paths.
my %EXPECTED_SPEC_PATHS = (
	'pve.host'             => undef,  # from bosh-configs.cpi, entombed
	'pve.port'             => 8006,
	'pve.user'             => undef,  # entombed
	'pve.realm'            => 'pam',
	'pve.password'         => '',
	'pve.node'             => undef,  # entombed
	'pve.vm_storage'       => 'local-lvm-data',
	'pve.disk_storage'     => 'local-lvm-data',
	'pve.stemcell_storage' => 'local',
	'pve.iso_storage'      => 'local',
	'pve.network_bridge'   => 'ocfp',
	'pve.verify_ssl'       => 0,
	'pve.vmid_range_start' => 200,
	'pve.agent_mode'       => 'cloudinit',
	'pve.vm_disk_format'   => 'raw',
	'agent.mbus'           => 'nats://10.115.16.4:4222',
);

# Walk a dotted path into the unflattened config.
sub at_path {
	my ($config, $path) = @_;
	my $node = $config;
	for my $seg (split /\./, $path) {
		return undef unless ref($node) eq 'HASH' && exists $node->{$seg};
		$node = $node->{$seg};
	}
	return $node;
}

# --- (a) every mapped property lands at its jobs/pve_cpi/spec path ------
subtest 'every mapped property is emitted at the path jobs/pve_cpi/spec declares' => sub {
	my $config = build_hook(%BASE_CPI)->gather_properties_for_pve;

	for my $path (sort keys %EXPECTED_SPEC_PATHS) {
		my @segs = split /\./, $path;
		my $leaf = pop @segs;
		my $parent = at_path($config, join('.', @segs));
		ok(
			ref($parent) eq 'HASH' && exists $parent->{$leaf},
			"$path is present at its nested spec path (cpi.json.erb reads it as p(\"$path\"))",
		);
	}

	# The whole point: the pve namespace is a nested hash, not a set of
	# top-level pve_-prefixed keys.
	is(ref($config->{pve}), 'HASH', 'pve properties are nested under a pve hash, not flattened into pve_* keys');
	is(ref($config->{agent}), 'HASH', 'agent.mbus is nested under an agent hash');
};

subtest 'mapped defaults and env values arrive with the right values' => sub {
	my $config = build_hook(%BASE_CPI)->gather_properties_for_pve;

	for my $path (sort keys %EXPECTED_SPEC_PATHS) {
		my $expected = $EXPECTED_SPEC_PATHS{$path};
		next unless defined $expected;   # entombed secrets checked in (b)
		is(at_path($config, $path), $expected, "$path carries its expected value");
	}
};

# --- no source key is left behind at the top level ---------------------
subtest 'no env-yml source key is left at the top level alongside its mapped path' => sub {
	my $config = build_hook(%BASE_CPI)->gather_properties_for_pve;

	my @stray = sort grep { /^pve_/ } keys %$config;
	is_deeply(
		\@stray, [],
		'no pve_* key survives at the top level; every one resolved to its pve.* path',
	);
};

# --- (b) `!` secrets stay entombed, with no cleartext twin -------------
subtest 'secret properties are entombed and never duplicated in cleartext' => sub {
	my $hook   = build_hook(%BASE_CPI);
	my $config = $hook->gather_properties_for_pve;

	my %secret_source_for = (
		'pve.host' => 'pve_host',
		'pve.user' => 'pve_user',
		'pve.node' => 'pve_node',
	);

	for my $path (sort keys %secret_source_for) {
		my $value = at_path($config, $path);
		like(
			$value, qr{^\(\(/cpi-config/properties/cpi-config-property--\Q$path\E--[0-9a-f]{8}\)\)$},
			"$path is a credhub reference, not the raw value",
		);
	}

	# The regression this guards: gather_properties' override pass keys off
	# the source key while the config hash is keyed by output path, so once
	# a >path is introduced the raw secret is copied straight back in.
	for my $path (sort keys %secret_source_for) {
		my $source = $secret_source_for{$path};
		ok(
			!exists $config->{$source},
			"raw secret is not re-emitted as top-level $source beside the entombed $path",
		);
	}

	my $cleartext = join "\n", map { "$_" } grep { !ref } values %$config;
	unlike($cleartext, qr/\Q$BASE_CPI{pve_user}\E/, 'pve_user cleartext appears nowhere at the top level');
	unlike($cleartext, qr/\Q$BASE_CPI{pve_node}\E/, 'pve_node cleartext appears nowhere at the top level');

	# The entombed values are still handed to credhub, so the reference resolves.
	my %entombed = map { $_ => 1 } values %{$hook->{credhub_secrets}};
	ok($entombed{$BASE_CPI{pve_host}}, 'pve_host value was handed to credhub for entombment');
	ok($entombed{$BASE_CPI{pve_user}}, 'pve_user value was handed to credhub for entombment');
	ok($entombed{$BASE_CPI{pve_node}}, 'pve_node value was handed to credhub for entombment');
};

# --- (c) a spruce operator never reaches the top level -----------------
subtest 'a spruce operator in a mapped key does not leak to the top level' => sub {
	my $config = build_hook(
		%BASE_CPI,
		pve_agent_mbus => '(( concat "nats://" params.static_ip ":4222" ))',
	)->gather_properties_for_pve;

	ok(
		!exists $config->{pve_agent_mbus},
		'unevaluated operator is not copied to a top-level pve_agent_mbus',
	);

	# Left at the top level, the director parses the bare (( ... )) as a BOSH
	# variable reference and rejects every deployment against it:
	#   Variable name ' concat "nats://" ... ' must only contain alphanumeric,
	#   underscores, dashes, or forward slash characters
	my @operator_keys = sort grep {
		!ref($config->{$_}) && defined($config->{$_}) && $config->{$_} =~ /^\(\(\s*\w+\s/
	} keys %$config;
	is_deeply(\@operator_keys, [], 'no top-level key carries an unevaluated spruce operator');
};

# --- (d) unmodeled keys still pass through -----------------------------
subtest 'keys the map does not model are still passed through' => sub {
	my $config = build_hook(
		%BASE_CPI,
		pve_log_level  => 'debug',        # real spec property, not in the map
		some_other_key => 'passthrough',  # not a pve property at all
	)->gather_properties_for_pve;

	is($config->{pve_log_level}, 'debug', 'an unmapped pve_* key is left for the override pass to carry');
	is($config->{some_other_key}, 'passthrough', 'an unrelated override key is untouched');
};

# --- optional properties stay optional ---------------------------------
subtest 'optional pve_api_token is omitted when unset and nested when set' => sub {
	my $without = build_hook(%BASE_CPI)->gather_properties_for_pve;
	ok(!exists $without->{pve}{api_token}, 'pve.api_token is omitted when the env does not set it');
	ok(!exists $without->{pve_api_token}, 'and no top-level pve_api_token appears either');

	my $with = build_hook(%BASE_CPI, pve_api_token => 'ocfp-cpi@pve!cpi=uuid')->gather_properties_for_pve;
	is($with->{pve}{api_token}, 'ocfp-cpi@pve!cpi=uuid', 'pve.api_token is nested at its spec path when set');
	ok(!exists $with->{pve_api_token}, 'and is not duplicated at the top level');
};

# --- the map itself is well-formed -------------------------------------
subtest 'every pve map entry declares an explicit output path' => sub {
	my @map = Test::FakeCpiConfig->_property_map_for_pve;
	is(scalar(@map), 17, 'the pve map has 17 entries');

	for my $property (@map) {
		my (undef, $key, undef, undef, undef, $path) =
			$property =~ /^(!?)([^\@:\?\>]+)(?:\@([^:\?\>]+))?(?:(?::([^>]+))|(\?))?(?:>(.+))?$/;
		ok(defined $path, "$key declares an explicit >path");
		like($path // '', qr/^(pve|agent)\./, "$key targets a nested spec namespace (pve.* or agent.*)");
	}

	my %paths = map {
		my (undef, undef, undef, undef, undef, $p) =
			$_ =~ /^(!?)([^\@:\?\>]+)(?:\@([^:\?\>]+))?(?:(?::([^>]+))|(\?))?(?:>(.+))?$/;
		($p => 1)
	} @map;
	# pve.api_token is optional, so it is absent from the default-render
	# expectations above but must still be declared by the map.
	is_deeply(
		[sort keys %paths],
		[sort (keys %EXPECTED_SPEC_PATHS, 'pve.api_token')],
		'the map targets exactly the jobs/pve_cpi/spec property set it claims to',
	);
};

done_testing;
