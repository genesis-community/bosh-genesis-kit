#!/usr/bin/env perl
# Unit tests for P2-T1 (_cpi_name_for_az / overridden build_az_definitions)
# in hooks/cloud-config-director.pm.
#
# hooks/cloud-config-director.pm's build_az_definitions is not reachable
# through genesis check/manifest/yamls -- Genesis only invokes it via
# run_hook('cloud-config', purpose => 'director'), which is called
# exclusively from Genesis::Hook::PostDeploy::update_director_network_config
# after a live, successful `bosh create-env`/director deploy. It cannot be
# exercised through spec/spec.t's genesis-manifest pipeline. This file loads
# the real hook module directly and drives its two new/changed methods
# against thin test doubles for the base-class collaborators (env, cpi_name,
# cpi_enabled, get_available_azs, _az_definition_for), so the code under
# test -- build_az_definitions, _cpi_name_for_az, and _validate_az_map_keys
# -- runs unmodified.
#
# get_available_azs keys used below are the OCFP vault AZ key names
# (net/azs/*, e.g. pvea, pved) -- the real production shape. Each AZ's
# rendered `name` (pve-multi-az-z1, pve-multi-az-z4, ...) is deliberately
# different from its vault key, so a test that only worked because key ==
# name (the z1/z2-keyed shape this file used to use) cannot pass here.
#
# Required cases:
#   (a) az_map absent  -> every AZ's cpi falls back to the base cpi_name,
#       byte-identical to the pre-P2-T1 single-CPI behavior.
#   (b) az_map present, keyed by real vault AZ keys -> each AZ resolves its
#       own mapped cpi name, and two AZs get two distinct cpi values; the
#       resolution is proven to go through the vault key, not the rendered
#       name.
#   (c) az_map keyed by a rendered `-zN` name instead of a vault AZ key ->
#       build_az_definitions bails (fatal config error), not a silent
#       single-CPI fallback. Locks the R3-05 contract: `-zN` keys never
#       work, and now the hook says so instead of mis-placing workloads.
# Plus defensive coverage: partial az_map, cpi_enabled=false, malformed
# az_map value.
use strict;
use warnings;
use FindBin;
use Test::More;

my $hook_file = "$FindBin::Bin/../../hooks/cloud-config-director.pm";
require $hook_file;

# --- Test doubles ------------------------------------------------------

package Test::FakeEnv;

sub new {
	my ($class, %data) = @_;
	return bless { data => \%data }, $class;
}

# Minimal stand-in for Genesis::Env::lookup: dotted-path traversal over a
# plain hash, returning $default when any segment is missing.
sub lookup {
	my ($self, $key, $default) = @_;
	my @path = split /\./, $key;
	my $node = $self->{data};
	for my $seg (@path) {
		return $default unless ref($node) eq 'HASH' && exists $node->{$seg};
		$node = $node->{$seg};
	}
	return $node;
}

package Test::FakeCloudConfigDirector;

# Inherit the real hook module under test -- build_az_definitions,
# _cpi_name_for_az, and _validate_az_map_keys are NOT overridden here, so
# they run as shipped in hooks/cloud-config-director.pm. Only base-class
# collaborators are stubbed.
our @ISA = ('Genesis::Hook::CloudConfigDirector::BOSH');

sub new {
	my ($class, %opts) = @_;
	return bless {
		env         => $opts{env},
		azs         => $opts{azs} // {},
		cpi_enabled => $opts{cpi_enabled} // 1,
		base_cpi    => $opts{base_cpi} // 'pve-bosh.pve.pve',
	}, $class;
}

sub env                { $_[0]->{env} }
sub cpi_enabled         { $_[0]->{cpi_enabled} }
sub cpi_name            { $_[0]->{base_cpi} }
sub get_available_azs   { $_[0]->{azs} }

# Mirrors the real base class's shape (Hook/CloudConfig.pm:1595-1603) minus
# the cpi assignment, which build_az_definitions overwrites regardless.
sub _az_definition_for {
	my ($self, $az, %options) = @_;
	return { name => $az->{name}, cloud_properties => {} };
}

package main;

# Genesis::bail() dies (rather than exiting the process) when called inside
# an eval -- see Genesis.pm's `if ($^S && ...) { die ... }` branch -- and
# wraps/colorizes the message for terminal display. Strip ANSI SGR codes
# and collapse the word-wrap's inserted whitespace/newlines so assertions
# can match the message as a single, contiguous string.
sub clean_bail_message {
	my ($msg) = @_;
	$msg =~ s/\e\[[0-9;]*m//g;
	$msg =~ s/\s+/ /g;
	$msg =~ s/^\s+|\s+\z//g;
	return $msg;
}

# --- (a) az_map absent: fallback to base cpi_name, byte-identical to today's
#     single-CPI-per-director behavior ----------------------------------
subtest 'az_map absent falls back to base cpi_name (byte-identical to baseline)' => sub {
	my $env = Test::FakeEnv->new;  # no bosh-configs.director-cpi.az_map at all
	my $hook = Test::FakeCloudConfigDirector->new(
		env      => $env,
		base_cpi => 'pve-bosh.pve.pve',
		azs      => {
			pvea => { name => 'pve-multi-az-z1' },
			pved => { name => 'pve-multi-az-z4' },
		},
	);
	my @azs = $hook->build_az_definitions;
	is(scalar(@azs), 2, 'two AZ definitions returned');
	my %by_name = map { $_->{name} => $_ } @azs;
	is($by_name{'pve-multi-az-z1'}{cpi}, 'pve-bosh.pve.pve', 'pvea (rendered z1) falls back to base cpi_name');
	is($by_name{'pve-multi-az-z4'}{cpi}, 'pve-bosh.pve.pve', 'pved (rendered z4) falls back to base cpi_name');
	is_deeply(
		[sort map { $_->{cpi} } @azs],
		['pve-bosh.pve.pve', 'pve-bosh.pve.pve'],
		'every az cpi equals the single-CPI baseline value -- no per-AZ divergence when az_map is absent',
	);
};

# --- (b) az_map present, keyed by real vault AZ keys: each AZ resolves its
#     own mapped cpi name via the vault key, not the rendered name --------
subtest 'az_map keyed by vault AZ keys resolves distinct per-AZ cpi names' => sub {
	my $env = Test::FakeEnv->new(
		'bosh-configs' => {
			'director-cpi' => {
				'az_map' => {
					pvea => 'pve-cpi',
					pved => 'pve-cpi-az2',
				},
			},
		},
	);
	my $hook = Test::FakeCloudConfigDirector->new(
		env      => $env,
		base_cpi => 'pve-bosh.pve.pve',
		azs      => {
			pvea => { name => 'pve-multi-az-z1' },
			pved => { name => 'pve-multi-az-z4' },
		},
	);
	my @azs = $hook->build_az_definitions;
	my %by_name = map { $_->{name} => $_ } @azs;
	is($by_name{'pve-multi-az-z1'}{cpi}, 'pve-cpi',     'AZ keyed pvea (rendered name pve-multi-az-z1, NOT "z1") gets its az_map-mapped cpi name');
	is($by_name{'pve-multi-az-z4'}{cpi}, 'pve-cpi-az2', 'AZ keyed pved (rendered name pve-multi-az-z4, NOT "z4") gets its own distinct az_map-mapped cpi name');
	isnt($by_name{'pve-multi-az-z1'}{cpi}, $by_name{'pve-multi-az-z4'}{cpi}, 'the two AZs resolve to two distinct cpi names');
};

# --- (c) az_map keyed by a rendered -zN name (not a vault AZ key) bails --
subtest 'az_map keyed by a rendered -zN name (not a vault AZ key) triggers a fatal config error' => sub {
	my $env = Test::FakeEnv->new(
		'bosh-configs' => {
			'director-cpi' => {
				# 'z1' is the rendered-name style (<env>-z<index>), never a
				# valid az_map key -- only 'pvea'/'pved' are.
				'az_map' => { z1 => 'pve-cpi' },
			},
		},
	);
	my $hook = Test::FakeCloudConfigDirector->new(
		env      => $env,
		base_cpi => 'pve-bosh.pve.pve',
		azs      => {
			pvea => { name => 'pve-multi-az-z1' },
			pved => { name => 'pve-multi-az-z4' },
		},
	);
	my @azs;
	eval { @azs = $hook->build_az_definitions };
	my $err = clean_bail_message($@);
	ok(length($err), 'build_az_definitions raised a fatal error instead of silently ignoring the bad az_map key');
	like($err, qr/unknown AZ key\(s\): 'z1'/, 'error names the offending az_map key');
	like(
		$err,
		qr/az_map keys must be the OCFP vault az keys \(net\/azs\/\*\), not the rendered -zN names/,
		'error explains the az_map key convention',
	);
	like($err, qr/Valid az keys for this environment: 'pvea', 'pved'/, 'error lists the valid az keys for this environment');
};

# --- Partial az_map: an AZ missing from az_map still falls back, and a
#     partial-but-entirely-valid az_map does NOT trigger the guard --------
subtest 'az not covered by az_map falls back to base cpi_name' => sub {
	my $env = Test::FakeEnv->new(
		'bosh-configs' => {
			'director-cpi' => {
				'az_map' => { pvea => 'pve-cpi' },  # pved intentionally absent
			},
		},
	);
	my $hook = Test::FakeCloudConfigDirector->new(
		env      => $env,
		base_cpi => 'pve-bosh.pve.pve',
		azs      => {
			pvea => { name => 'pve-multi-az-z1' },
			pved => { name => 'pve-multi-az-z4' },
		},
	);
	my @azs = $hook->build_az_definitions;
	my %by_name = map { $_->{name} => $_ } @azs;
	is($by_name{'pve-multi-az-z1'}{cpi}, 'pve-cpi',          'pvea uses its az_map entry');
	is($by_name{'pve-multi-az-z4'}{cpi}, 'pve-bosh.pve.pve', 'pved (not in az_map) falls back to base cpi_name, no error');
};

# --- cpi_enabled=0: no cpi key injected at all, az_map or not, and the
#     az_map-key guard is skipped entirely (nothing to validate for) ------
subtest 'cpi_enabled false suppresses the cpi key entirely, az_map or not' => sub {
	my $env = Test::FakeEnv->new(
		'bosh-configs' => { 'director-cpi' => { 'az_map' => { pvea => 'pve-cpi' } } },
	);
	my $hook = Test::FakeCloudConfigDirector->new(
		env         => $env,
		cpi_enabled => 0,
		azs         => { pvea => { name => 'pve-multi-az-z1' } },
	);
	my @azs = $hook->build_az_definitions;
	ok(!exists $azs[0]{cpi}, 'no cpi key set when cpi_enabled is false');
};

# --- Defensive: malformed az_map value doesn't die, just falls back ----
subtest '_cpi_name_for_az defensive: non-hash az_map value falls back safely' => sub {
	my $env = Test::FakeEnv->new(
		'bosh-configs' => { 'director-cpi' => { 'az_map' => 'not-a-hash' } },
	);
	my $hook = Test::FakeCloudConfigDirector->new(env => $env, base_cpi => 'pve-bosh.pve.pve');
	is(
		$hook->_cpi_name_for_az('pvea'), 'pve-bosh.pve.pve',
		'malformed az_map falls back to base cpi_name, does not die',
	);
};

done_testing;
