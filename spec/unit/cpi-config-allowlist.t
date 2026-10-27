#!/usr/bin/env perl
# Unit test that hooks/cpi-config.pm emits no CPI context key the pve_cpi job
# spec does not define.
#
# bosh-proxmox-cpi 0.9.4 and later check every key of the cpi-config context
# against jobs/pve_cpi/spec and reject the request with "context override
# rejected" when one is missing. The override pass in gather_properties copies
# any bosh-configs.cpi key the pve map does not model straight into the cpi
# config, so a key the kit reads for itself leaks into the context unless the
# hook strips it. The strip is a denylist (_drop_pve_kit_consumed_keys), which
# a new kit-only pve_* key silently bypasses. This file checks the output
# against an allowlist instead.
#
# The rule mirrors InspectContextKeys and specKnownPVEKey in
# src/pve_cpi/internal/config/context_override_keys.go at CPI v0.9.5:
#   - a flat pve_<name> key is accepted when <name> is a spec name under pve.
#     with its dots written as underscores (pve_placement_enabled), or is the
#     remainder or first segment of a spec name (pve_placement, pve_vm_types),
#   - a key under the pve map is accepted on the same remainder or first
#     segment test, and a key under the agent map on the agent. spec names,
#   - the CPI also accepts its own request-override field names that the spec
#     does not list; this test does not, so it is stricter than the CPI.
#
# The pve_* keys fed to the hook are derived, not hand-listed: every key in
# the pve property map and its alternates, every bosh-configs.cpi.pve_* key
# the hooks and the ocfp and overlay YAML read, and the keys the hook's drop
# helpers name. The first two sources do not depend on the denylist under test.
#
# The hook has no feature branches, so the variations that change its output
# are the two cpi configs Genesis builds (own-director and child) and the
# flat or nested spelling of a key.
use strict;
use warnings;
use FindBin;
use File::Find ();
use Test::More;

my $kit_dir   = "$FindBin::Bin/../..";
my $hook_file = "$kit_dir/hooks/cpi-config.pm";
require $hook_file;

# --- Fixture: pve_cpi job spec property names ----------------------------
my $fixture = "$FindBin::Bin/fixtures/pve_cpi-spec-properties.txt";
open(my $fh, '<', $fixture) or die "cannot read $fixture: $!";
my (%pve, %pve_flat, %agent);
while (my $line = <$fh>) {
	chomp $line;
	next if $line =~ /^\s*(#|$)/;
	my ($scope, $rest) = split /\./, $line, 2;
	next unless defined $rest;
	if ($scope eq 'pve') {
		$pve{$rest} = 1;
		(my $flat = $rest) =~ s/\./_/g;
		$pve_flat{$flat} = 1;
		my ($first, $more) = split /\./, $rest, 2;
		$pve{$first} = 1 if defined $more;
	} elsif ($scope eq 'agent') {
		$agent{$rest} = 1;
		my ($first, $more) = split /\./, $rest, 2;
		$agent{$first} = 1 if defined $more;
	}
}
close $fh;
cmp_ok(scalar(keys %pve), '>', 100, 'the fixture lists the pve.* spec properties');

# --- Test doubles --------------------------------------------------------

package Test::FakeEnv;

sub new {
	my ($class, %opts) = @_;
	return bless { data => $opts{data} // {}, director_exodus => $opts{director_exodus} // {} }, $class;
}

sub lookup {
	my ($self, $key, $default) = @_;
	my @path = map {
		my ($name, $indices) = /^(.*?)((?:\[\d+\])+)$/;
		defined $indices ? ($name, $indices =~ /\[(\d+)\]/g) : ($_)
	} split /\./, $key;
	my $node = $self->{data};
	for my $seg (@path) {
		if (ref($node) eq 'ARRAY' && $seg =~ /^\d+$/ && $seg < @$node) {
			$node = $node->[$seg];
			next;
		}
		return (wantarray ? ($default, 0) : $default)
			unless ref($node) eq 'HASH' && exists $node->{$seg};
		$node = $node->{$seg};
	}
	return wantarray ? ($node, 1) : $node;
}

sub lookup_entombed      { my $s = shift; $s->lookup(@_) }
sub lookup_entombed_self { my $s = shift; $s->lookup(@_) }
sub lookup_unevaled      { my ($s, $key) = @_; $s->lookup($key, {}) }
sub ocfp_config_lookup   { (undef, 0) }
sub cpi_credhub_base     { '/cpi-config/properties/' }
sub director_exodus_lookup { $_[0]->{director_exodus}{$_[1]} }

package Test::FakeCpiConfig;
our @ISA = ('Genesis::Hook::CpiConfig::BOSH');

sub new {
	my ($class, %opts) = @_;
	return bless {
		env             => $opts{env},
		credhub_secrets => {},
		credhub_prefix  => $opts{credhub_prefix},
	}, $class;
}

sub env  { $_[0]->{env} }
sub iaas { 'pve' }

package main;

# --- Derive the pve_* params the kit reads --------------------------------
sub slurp {
	my ($file) = @_;
	open(my $in, '<', $file) or die "cannot read $file: $!";
	local $/;
	return scalar <$in>;
}

sub find_yaml {
	my ($dir) = @_;
	my @files;
	File::Find::find({ no_chdir => 1, wanted => sub { push @files, $File::Find::name if /\.yml$/ } }, $dir);
	return sort @files;
}

sub derive_params {
	my %params;

	# The pve property map: each lookup key and each @alternate.
	for my $entry (Test::FakeCpiConfig->_property_map_for_pve) {
		my (undef, $key, $alts) =
			$entry =~ /^(!?)([^\@:\?\>]+)(?:\@([^:\?\>]+))?(?:(?::([^>]+))|(\?))?(?:>(.+))?$/;
		$params{$_} = 1 for grep { /^pve_\w+$/ } ($key, split(/,/, $alts // ''));
	}

	# Every bosh-configs.cpi.pve_* reference in the hooks and in the YAML the
	# kit merges. These sources do not depend on the hook's drop helpers, so a
	# key removed from a denylist is still fed to the hook.
	my @sources = (
		glob("$kit_dir/hooks/*.pm"),
		find_yaml("$kit_dir/ocfp"),
		find_yaml("$kit_dir/overlay"),
	);
	for my $file (@sources) {
		my $text = slurp($file);
		$params{$1} = 1 while $text =~ /bosh-configs\.cpi\.(pve_\w+)/g;
	}

	# The drop helpers' qw lists name keys without the pve_ prefix. They are an
	# extra source only, and a helper with no list means the parse is stale.
	my $src = slurp($hook_file);
	while ($src =~ /^sub (_drop_pve_\w+)\b(.*?)^\}/msg) {
		my ($name, $body) = ($1, $2);
		my @lists = $body =~ /\bqw\s*(?:\/(.*?)\/|\((.*?)\)|\[(.*?)\]|\{(.*?)\}|<(.*?)>|!(.*?)!)/sg;
		my @words = map { split ' ', $_ } grep { defined } @lists;
		die "no qw list found in $name; update derive_params in $0\n" unless @words;
		$params{"pve_$_"} = 1 for @words;
	}
	return sort keys %params;
}

my @params = derive_params();
cmp_ok(scalar(@params), '>=', 25, 'derived the pve_* params the kit reads from the hook sources');
ok((grep { $_ eq 'pve_disk_format' } @params), 'the derivation finds a kit-consumed key from a drop helper');
ok((grep { $_ eq 'pve_bosh_cpu' } @params), 'the derivation finds a kit-consumed key from another hook');
ok((grep { $_ eq 'pve_host_operator' } @params), 'the derivation finds a kit-consumed key from the YAML, not the denylist');
ok((grep { $_ eq 'pve_storage_capacity_domains' } @params), 'the derivation finds a pass-through key from the YAML');
ok((grep { $_ eq 'pve_storage_placement_namespace' } @params), 'the derivation finds a key from the child-config helper');
ok((grep { $_ eq 'pve_host' } @params), 'the derivation finds a key from the property map');

# --- Emit and check -------------------------------------------------------
my $DIRECTOR_PREFIX = '/cpi-config/properties/';
my $CHILD_PREFIX    = '/lab-mgmt-bosh/lab-ocf-bosh/genesis-entombed/';

sub emitted_for {
	my (%opts) = @_;
	my $env = Test::FakeEnv->new(
		data => {
			'bosh-configs' => { cpi => $opts{cpi} },
			params         => { static_ip => '10.115.20.64' },
		},
		director_exodus => { url => 'https://10.115.16.4:25555' },
	);
	return Test::FakeCpiConfig->new(env => $env, credhub_prefix => $opts{prefix})
		->gather_properties_for_pve;
}

# Names of the context keys the CPI would reject, as it spells them.
sub rejected_keys {
	my ($config) = @_;
	my @bad;
	for my $key (sort keys %$config) {
		if ($key eq 'pve' || $key eq 'agent') {
			my $value = $config->{$key};
			if (ref($value) ne 'HASH') {
				push @bad, $key;
				next;
			}
			my $known = $key eq 'pve' ? \%pve : \%agent;
			push @bad, map { "$key.$_" } grep { !$known->{$_} } sort keys %$value;
		} elsif ($key =~ /^pve_(.+)$/) {
			my $name = $1;
			push @bad, $key unless $pve_flat{$name} || $pve{$name};
		} else {
			push @bad, $key;
		}
	}
	return @bad;
}

my %scalars = map { $_ => "value-for-$_" } @params;

# pve_agent_mbus is the map's flat spelling of agent.mbus, so it has no pve.* form.
my @nested = grep { $_ ne 'pve_agent_mbus' } @params;

my @cases = (
	['own-director, flat keys',  $DIRECTOR_PREFIX, { %scalars }],
	['child, flat keys',         $CHILD_PREFIX,    { %scalars }],
	['own-director, nested keys', $DIRECTOR_PREFIX, { pve => { map { (s/^pve_//r) => "v" } @nested } }],
	['child, nested keys',        $CHILD_PREFIX,    { pve => { map { (s/^pve_//r) => "v" } @nested } }],
);

for my $case (@cases) {
	my ($label, $prefix, $cpi) = @$case;
	subtest "$label emits only keys the pve_cpi spec defines" => sub {
		# The nested-key cases make the hook warn about keys it ignores.
		my $config;
		{
			local *STDERR;
			open(STDERR, '>', \my $warned) or die "cannot capture STDERR: $!";
			$config = emitted_for(cpi => $cpi, prefix => $prefix);
		}
		my @bad = rejected_keys($config);
		is(scalar(@bad), 0, 'no emitted context key is missing from the spec')
			or diag("the CPI would reject these context keys: " . join(', ', @bad));
		is(ref($config->{pve}), 'HASH', 'the hook emitted a pve context to check');
	};
}

done_testing;
