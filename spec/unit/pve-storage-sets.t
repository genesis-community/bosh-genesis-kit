#!/usr/bin/env perl
# Unit tests for the pve-storage-sets feature: the spruce layer
# ocfp/pve/storage-sets.yml and the ops file overlay/cpis/pve-storage-sets.yml.
#
# spec/spec.t cannot cover either file. Both load only when the ocfp feature is
# active, and no ocfp env can be spec-tested: the ocfp path needs bloc config in
# vault (secret/config/<bloc>/...) and a live create-env, neither of which the
# validator sandbox provides (see the NOTE in spec/spec.t). So this file drives
# the two files directly with the same tools genesis uses, spruce for the merge
# and bosh int for the ops pass, against a stub of the manifest
# overlay/cpis/pve-base.yml produces.
#
# Required cases:
#   (a) the defaults resolve: the placement namespace falls back to the env
#       name, the journal directory to the director's persistent disk, the
#       capacity domains to an empty map, and both role bindings to "".
#       An empty capacity-domain map is what the CPI's strict decoder accepts:
#       ValidateStoragePlacement iterates the map, so zero entries raise
#       nothing (src/pve_cpi/internal/config/storage_placement.go).
#   (b) an env's own values win, and maps survive as YAML structures rather
#       than being stringified. That is the whole risk in passing a map through
#       a ((var)) reference.
#   (c) enabling the feature without declaring any set fails the merge and
#       names the key the operator has to set.
#   (d) every property lands under the director's own CPI job, and NOTHING
#       lands under cloud_provider. The CPI refuses a set-managed placement
#       until it can lock the journal directory, and create-env runs the CPI
#       where /var/vcap/store does not exist.
#   (e) the feature emits none of the three optional CPI keys it does not
#       model, so an env that needs them reaches for bosh-configs.director-cpi.
use strict;
use warnings;
use FindBin;
use File::Temp qw/tempdir/;
use JSON::PP;
use Test::More;

my $KIT   = "$FindBin::Bin/../..";
my $LAYER = "$KIT/ocfp/pve/storage-sets.yml";
my $OPS   = "$KIT/overlay/cpis/pve-storage-sets.yml";

ok(-f $LAYER, 'ocfp/pve/storage-sets.yml exists');
ok(-f $OPS,   'overlay/cpis/pve-storage-sets.yml exists');

my $tmp = tempdir(CLEANUP => 1);

sub write_file {
	my ($path, $body) = @_;
	open my $fh, '>', $path or die "cannot write $path: $!";
	print $fh $body;
	close $fh;
	return $path;
}

# Run spruce over the layer plus an env-file stub, and hand back the merged
# tree. Returns (tree, error-output); exactly one of the two is defined.
sub merge_layer {
	my ($stub_body, $tag) = @_;
	my $stub = write_file("$tmp/stub-$tag.yml", $stub_body);
	my $out  = qx{spruce merge '$LAYER' '$stub' 2>&1};
	return (undef, $out) if $? != 0;
	my $json = qx{spruce json '$tmp/merged-$tag.yml' 2>&1}
		if write_file("$tmp/merged-$tag.yml", $out);
	die "spruce json failed: $json" if $? != 0;
	return (decode_json($json), undef);
}

# The stub of what overlay/cpis/pve-base.yml leaves behind: the director's own
# CPI job properties and the create-env cloud_provider block, both already
# carrying the scalar placement keys the sets never replace.
my $MANIFEST = write_file("$tmp/manifest.yml", <<'YAML');
---
instance_groups:
- name: bosh
  properties:
    pve:
      vm_storage: test-vm-storage
      disk_storage: test-disk-storage
      stemcell_storage: test-stemcell-storage
cloud_provider:
  template:
    name: pve_cpi
    release: bosh-proxmox-cpi
  properties:
    pve:
      vm_storage: test-vm-storage
      disk_storage: test-disk-storage
      stemcell_storage: test-stemcell-storage
YAML

# Apply the ops file the way genesis does, with the layer's bosh-variables as
# the vars file.
sub apply_ops {
	my ($vars, $tag) = @_;
	my $vars_file = write_file("$tmp/vars-$tag.yml", encode_json($vars));
	my $out = qx{bosh int '$MANIFEST' -o '$OPS' -l '$vars_file' 2>&1};
	die "bosh int failed:\n$out" if $? != 0;
	my $rendered = write_file("$tmp/rendered-$tag.yml", $out);
	my $json = qx{spruce json '$rendered' 2>&1};
	die "spruce json failed:\n$json" if $? != 0;
	return decode_json($json);
}

my $SETS_ONLY = <<'YAML';
---
genesis:
  env: lab-mgmt
bosh-configs:
  cpi:
    pve_storage_sets:
      ephemeral:
        names: [ns-1, ns-2]
        types: [nfs]
        shared: true
        max_utilization_pct: 85
        strategy: { name: weighted_free_space, version: 1 }
YAML

# --- (a) defaults ------------------------------------------------------
subtest 'an env that declares only its sets gets every other value defaulted' => sub {
	my ($tree, $err) = merge_layer($SETS_ONLY, 'defaults');
	ok(!defined $err, 'the merge succeeds') or diag($err);
	my $vars = $tree->{'bosh-variables'};

	is($vars->{pve_storage_placement_namespace}, 'lab-mgmt',
		'the placement namespace defaults to the env name, which is stable across CPI restarts');
	is($vars->{pve_storage_allocation_journal_dir}, '/var/vcap/store/pve_cpi/allocations',
		'the journal directory defaults to the director persistent disk');
	is_deeply($vars->{pve_storage_capacity_domains}, {},
		'capacity domains default to an empty map, which the CPI decoder accepts');
	is($vars->{pve_ephemeral_storage_set}, '',
		'an unbound ephemeral role stays on its scalar pool');
	is($vars->{pve_persistent_storage_set}, '',
		'an unbound persistent role stays on its scalar pool');

	# params carry the same values, so an operator can read them back.
	is($tree->{params}{pve_storage_placement_namespace}, 'lab-mgmt',
		'params mirror the resolved namespace');
};

# --- (b) env values win, and maps stay maps -----------------------------
my $FULL = <<'YAML';
---
genesis:
  env: lab-mgmt
bosh-configs:
  cpi:
    pve_storage_sets:
      ephemeral:
        names: [pvuproxcf1_ns_1, pvuproxcf1_ns_2]
        types: [nfs]
        shared: true
        max_utilization_pct: 85
        strategy: { name: weighted_free_space, version: 1 }
      persistent:
        names: [pvuproxcf1_1]
        types: [nfs]
        shared: true
        strategy: { name: spread, version: 1 }
    pve_ephemeral_storage_set: ephemeral
    pve_persistent_storage_set: persistent
    pve_storage_capacity_domains:
      byua0805-nfs:
        members: [pvuproxcf1_ns_1]
      byua0806-nfs:
        members: [pvuproxcf1_ns_2, pvuproxcf1_1]
    pve_storage_placement_namespace: ocfp-cf1-lab-mgmt
    pve_storage_allocation_journal_dir: /var/vcap/store/pve_cpi/allocations
YAML

subtest "an env's own values win, and maps survive as structures" => sub {
	my ($tree, $err) = merge_layer($FULL, 'full');
	ok(!defined $err, 'the merge succeeds') or diag($err);
	my $vars = $tree->{'bosh-variables'};

	is($vars->{pve_storage_placement_namespace}, 'ocfp-cf1-lab-mgmt',
		'an explicit namespace overrides the env-name default');
	is($vars->{pve_ephemeral_storage_set},  'ephemeral',  'the ephemeral binding passes through');
	is($vars->{pve_persistent_storage_set}, 'persistent', 'the persistent binding passes through');

	is(ref($vars->{pve_storage_sets}), 'HASH', 'the storage sets arrive as a map, not a string');
	is_deeply(
		[sort keys %{ $vars->{pve_storage_sets} }], [qw/ephemeral persistent/],
		'both declared sets are present',
	);
	is_deeply(
		$vars->{pve_storage_sets}{ephemeral}{names}, [qw/pvuproxcf1_ns_1 pvuproxcf1_ns_2/],
		'a set keeps its member list in order',
	);
	is($vars->{pve_storage_sets}{ephemeral}{strategy}{name}, 'weighted_free_space',
		'a set keeps its nested strategy');
	is_deeply(
		$vars->{pve_storage_capacity_domains}{'byua0806-nfs'}{members},
		[qw/pvuproxcf1_ns_2 pvuproxcf1_1/],
		'a capacity domain keeps its member list',
	);
};

# --- (c) the feature without any set is an error ------------------------
subtest 'enabling the feature without declaring a set fails and names the key' => sub {
	my ($tree, $err) = merge_layer(<<'YAML', 'nosets');
---
genesis:
  env: lab-mgmt
bosh-configs:
  cpi:
    pve_vm_storage: test-vm-storage
YAML
	ok(!defined $tree, 'the merge fails rather than rendering a set-less placement');
	like($err // '', qr/pve_storage_sets/,
		'the error names bosh-configs.cpi.pve_storage_sets, so the operator knows what to set');
};

# --- (d) director job only, never cloud_provider ------------------------
my @PLACEMENT_KEYS = qw/
	storage_sets ephemeral_storage_set persistent_storage_set
	storage_capacity_domains storage_placement_namespace
	storage_allocation_journal_dir
/;

subtest 'every property lands on the director CPI job and none on cloud_provider' => sub {
	my ($tree) = merge_layer($FULL, 'ops');
	my $rendered = apply_ops($tree->{'bosh-variables'}, 'ops');

	my ($ig) = grep { $_->{name} eq 'bosh' } @{ $rendered->{instance_groups} };
	my $director = $ig->{properties}{pve};
	my $proto    = $rendered->{cloud_provider}{properties}{pve};

	for my $key (@PLACEMENT_KEYS) {
		ok(exists $director->{$key}, "pve.$key is set on the director's own CPI job");
		ok(!exists $proto->{$key},
			"pve.$key is absent from cloud_provider, where the CPI cannot lock a journal");
	}

	is($director->{storage_placement_namespace}, 'ocfp-cf1-lab-mgmt',
		'the namespace arrives interpolated, not as a ((var)) token');
	is(ref($director->{storage_sets}), 'HASH',
		'bosh int interpolates the map as a structure, so the CPI decoder sees an object');
	is($director->{storage_sets}{persistent}{strategy}{version}, 1,
		'a strategy version arrives as a number the strict decoder accepts');

	# The scalar keys are the fallback for every role no set binds, and stemcell
	# templates are never part of a set, so none of the three may be disturbed.
	is($director->{vm_storage},       'test-vm-storage',       'vm_storage is untouched');
	is($director->{disk_storage},     'test-disk-storage',     'disk_storage is untouched');
	is($director->{stemcell_storage}, 'test-stemcell-storage', 'stemcell_storage is untouched');
	is($proto->{vm_storage}, 'test-vm-storage',
		'the create-env block keeps the scalar placement it has always had');
};

# --- (e) the optional keys stay out of the feature ----------------------
subtest 'the three optional CPI keys are not emitted by this feature' => sub {
	my ($tree) = merge_layer($FULL, 'optional');
	my $rendered = apply_ops($tree->{'bosh-variables'}, 'optional');
	my ($ig) = grep { $_->{name} eq 'bosh' } @{ $rendered->{instance_groups} };

	for my $key (qw/root_storage_set require_disjoint_storage_sets storage_status_max_age_seconds/) {
		ok(!exists $ig->{properties}{pve}{$key},
			"pve.$key is left to bosh-configs.director-cpi rather than modelled here");
	}

	# require_disjoint_storage_sets defaults to true in the CPI whenever both
	# bindings exist, which is exactly this env, so leaving it unset is the
	# safe reading rather than an omission.
	ok(!exists $tree->{'bosh-variables'}{pve_require_disjoint_storage_sets},
		'and the layer declares no bosh-variable for it either');
};

done_testing;
