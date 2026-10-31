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
#   (e) the child config the parent director consumes carries neither the
#       placement namespace nor the journal directory, so the parent records
#       the new director's VM under its own enrolled authority. The storage
#       sets still pass through, and the own-director config keeps both keys.
#   (f) keys the kit consumes itself -- pve_host_operator, pve_disk_format,
#       and the pve_bosh_* and pve_compilation_* sizing keys -- never reach
#       the cpi config as context overrides, because CPI 0.9.4 and later
#       reject any context key jobs/pve_cpi/spec does not define. The env
#       keeps them for the hooks and overlays that read them, and
#       pve.vm_disk_format is still mapped.
#   (g) the PVE credentials, pve.api_token and pve.password, are entombed on
#       both destinations and never appear in cleartext.  Exactly one of
#       them must be set, vault values are read as raw strings, and the
#       returned config is checked as a whole so a credential that skipped
#       the resolver, such as one from a block given as an expression, is
#       refused.  The own-director config reads only lookup_entombed_self
#       and the parent copy only lookup_entombed.
use strict;
use warnings;
use FindBin;
use Test::More;
use JSON::PP ();

my $hook_file = "$FindBin::Bin/../../hooks/cpi-config.pm";
require $hook_file;

# --- Test doubles ------------------------------------------------------

package Test::FakeEnv;

use Storable ();

# data          - the env as written: lookup_unevaled reads it, and so does
#                 lookup, which the hook uses for params.
# entombed      - what lookup_entombed returns (the manifest entombed into
#                 the parent's CredHub), falling back to data.
# entombed_self - what lookup_entombed_self returns (the manifest entombed
#                 into the director's own CredHub), falling back to data.
# ocfp          - the OCFP config in vault, holding raw strings as vault does.
sub new {
	my ($class, %opts) = @_;
	return bless {
		data           => $opts{data} // {},
		entombed       => $opts{entombed},
		entombed_self  => $opts{entombed_self},
		ocfp           => $opts{ocfp} // {},
		calls          => [],
		credhub_writes => [],
	}, $class;
}

# Walk a dotted key the way Genesis::Env::lookup does, returning the found
# flag in list context. gather_properties treats the second element as
# "found", so it has to be real: returning a bare undef value would send
# every lookup down the ocfp_config_lookup fallback instead.
#
# The override pass flattens bosh-configs.cpi to leaves and looks each one up
# by its flattened name, which spells an array element as name[0], so the
# double walks those indices the way Genesis::Env::lookup does. A key with a
# trailing dot names its parent, as Perl's split drops the empty last field
# there too.
sub _walk {
	my ($root, $key, $default) = @_;
	my @path = map {
		my ($name, $indices) = /^(.*?)((?:\[\d+\])+)$/;
		defined $indices ? ($name, $indices =~ /\[(\d+)\]/g) : ($_)
	} split /\./, $key;
	my $node = $root;
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

sub lookup {
	my ($self, $key, $default) = @_;
	return _walk($self->{data}, $key, $default);
}

# Genesis::Hook::CpiConfig reads every operator value through
# lookup_entombed for the parent copy, or lookup_entombed_self for a
# director's own config, so an env-file (( vault )) arrives already
# entombed. Each has its own view so a test can prove which one was read,
# and each call is logged as parent:<key> or self:<key>.
#
# Building the entombed manifest writes every vault value it uses into the
# target CredHub, and that happens on the first entombed lookup of a run.
# The double records it in credhub_writes. A copy is returned so the hook's
# unflatten cannot reach back into the fixture.
sub _entombed_lookup {
	my ($self, $view, $tag, $key, $default) = @_;
	my $root = $self->{$view} // $self->{data};
	unless ($self->{entombed_built}{$view}++) {
		my $flat = Genesis::flatten({}, '', $root);
		push @{$self->{credhub_writes}}, map { "$tag:$_" } grep { defined && !ref } @{$flat}{sort keys %$flat};
	}
	push @{$self->{calls}}, "$tag:$key";
	my ($value, $found) = _walk($root, $key, $default);
	$value = Storable::dclone($value) if ref($value) eq 'HASH' || ref($value) eq 'ARRAY';
	return wantarray ? ($value, $found) : $value;
}

sub lookup_entombed {
	my ($self, $key, $default) = @_;
	return $self->_entombed_lookup('entombed', 'parent', $key, $default);
}

sub lookup_entombed_self {
	my ($self, $key, $default) = @_;
	return $self->_entombed_lookup('entombed_self', 'self', $key, $default);
}

# The env yml is not spruce-evaluated here, which matches the real
# lookup_unevaled: the override pass deliberately reads raw values.
sub lookup_unevaled {
	my ($self, $key) = @_;
	return scalar $self->lookup($key, {});
}

# The OCFP config as vault holds it: the stored string, untouched, with a
# found flag. Genesis JSON-decodes what this returns; the kit must not.
sub ocfp_config_lookup {
	my ($self, $key, $default) = @_;
	return _walk($self->{ocfp}, $key, $default);
}

sub ocfp_config_base { '/secret/config/lab/mgmt' }

sub cpi_credhub_base { '/cpi-config/properties/' }

# Stand-in for Genesis::Env::director_exodus_lookup. The real one returns the
# caller-supplied default (undef here) for a create-env environment, which has
# no parent director to look up; a child environment gets its parent's exodus.
sub director_exodus_lookup {
	my ($self, $key) = @_;
	return $self->{director_exodus}{$key};
}

# The shape of a Genesis that predates destination-aware lookups: it has
# lookup_entombed_self but no lookup_entombed.
package Test::FakeEnvWithoutLookupEntombed;

sub new { bless {}, shift }
sub lookup_entombed_self { return (undef, 0) }

package Test::FakeCpiConfig;

# Inherit the real hook module under test -- _property_map_for_pve and
# gather_properties_for_pve are NOT overridden here, so they run as
# shipped. Only the env-side collaborators are stubbed.
our @ISA = ('Genesis::Hook::CpiConfig::BOSH');

# Genesis passes self_upload => 1 for the director's own config and leaves it
# out for the parent copy, and the base class reads it to pick the lookup.
sub new {
	my ($class, %opts) = @_;
	return bless {
		env             => $opts{env},
		credhub_secrets => {},
		credhub_prefix  => $opts{credhub_prefix},
		self_upload     => $opts{self_upload},
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

# A hook built the way Genesis builds each of the two cpi configs: with a
# credhub_prefix for the director this environment deploys, without one for
# the child config the parent director consumes.
#
# cpi is the env file's bosh-configs.cpi as written. evaluated, entombed and
# entombed_self replace it in the entombed views, for a block that Spruce
# evaluates into something else. vault is the OCFP config's cpi/pve secret.
sub build_hook_for {
	my (%opts) = @_;
	my $params = $opts{params} // {};
	my $view = sub {
		my ($cpi) = @_;
		return undef unless defined $cpi;
		return { 'bosh-configs' => { cpi => $cpi }, params => $params };
	};
	my $env = Test::FakeEnv->new(
		data => {
			'bosh-configs' => { cpi => $opts{cpi} // {} },
			params => $params,
		},
		entombed      => $view->($opts{entombed} // $opts{evaluated}),
		entombed_self => $view->($opts{entombed_self} // $opts{evaluated}),
		ocfp          => { cpi => { pve => $opts{vault} // {} } },
	);
	$env->{director_exodus} = $opts{director_exodus} // {};
	return Test::FakeCpiConfig->new(
		env            => $env,
		credhub_prefix => $opts{credhub_prefix},
		self_upload    => $opts{self_upload},
	);
}

# The two credhub_prefix values Genesis passes, one per cpi config it builds:
# its default for the environment's own director, and the environment's
# cpi_credhub_base for the child config the parent director consumes.
my $DIRECTOR_PREFIX = '/cpi-config/properties/';
my $CHILD_PREFIX    = '/lab-mgmt-bosh/lab-ocf-bosh/genesis-entombed/';

# The director's own config, which Genesis uploads in post-deploy and reads
# through lookup_entombed_self, and the parent copy, read through
# lookup_entombed. Both default the inputs agent.mbus needs.
sub own_hook {
	my (%opts) = @_;
	return build_hook_for(
		params          => { static_ip => '10.115.20.64' },
		director_exodus => { url => 'https://10.115.16.4:25555' },
		%opts,
		credhub_prefix  => $DIRECTOR_PREFIX,
		self_upload     => 1,
	);
}

sub parent_hook {
	my (%opts) = @_;
	return build_hook_for(
		params          => { static_ip => '10.115.20.64' },
		director_exodus => { url => 'https://10.115.16.4:25555' },
		%opts,
		credhub_prefix  => $CHILD_PREFIX,
	);
}

# Each destination as [label, credhub prefix, hook builder, lookup tag].
my @DESTINATIONS = (
	['own-director', $DIRECTOR_PREFIX, \&own_hook,    'self'],
	['parent copy',  $CHILD_PREFIX,    \&parent_hook, 'parent'],
);

# Synthetic credentials only. The token has the user@realm!id=secret shape
# of a real PVE API token, which is not valid JSON.
my $TOKEN    = 'kit-test@pve!unit=00000000-0000-0000-0000-000000000000';
my $PASSWORD = 'SYNTHETIC-PASSWORD';

# What an OCFP bloc's vault holds besides the credential.
my %VAULT_BASE = (
	host => '10.115.16.1',
	user => 'ocfp-cpi@pve',
	node => 'lab-pipes-0',
);

my %BASE_CPI = (
	pve_host           => '10.115.16.1',
	pve_user           => 'ocfp-cpi@pve',
	pve_node           => 'lab-pipes-0',
	pve_api_token      => $TOKEN,
	pve_vm_storage     => 'local-lvm-data',
	pve_disk_storage   => 'local-lvm-data',
	pve_network_bridge => 'ocfp',
	pve_verify_ssl     => 0,
	pve_agent_mbus     => 'nats://10.115.16.4:4222',
);

# The same block with no credential at all, which the hook refuses.
my %NO_CREDENTIAL_CPI = map { ($_ => $BASE_CPI{$_}) } grep { $_ ne 'pve_api_token' } keys %BASE_CPI;

# Property names as declared in jobs/pve_cpi/spec of bosh-proxmox-cpi-release,
# and read back by jobs/pve_cpi/templates/cpi.json.erb via p("pve.host"),
# p("pve.node"), ... and if_p("agent.mbus"). Nothing the map emits is read
# by the job unless it arrives at one of these paths.
my %EXPECTED_SPEC_PATHS = (
	'pve.host'             => undef,  # from bosh-configs.cpi, entombed
	'pve.port'             => 8006,
	'pve.user'             => undef,  # entombed
	'pve.realm'            => 'pam',
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
	'pve.parker_prefix'    => 'bosh',
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

# Run the gather the way Genesis does, inside an eval, and return the config
# and the bail text. bail() colours and wraps its message, so the text comes
# back with the colour codes and the [FATAL] prefix stripped and all
# whitespace collapsed to single spaces. Warnings are swallowed.
sub try_gather {
	my ($hook) = @_;
	my $config;
	{
		local *STDERR;
		open(STDERR, '>', \my $warned) or die "cannot capture STDERR: $!";
		$config = eval { $hook->gather_properties_for_pve };
	}
	my $err = $@ // '';
	$err =~ s/\e\[[0-9;]*m//g;
	$err =~ s/\[FATAL\]//g;
	$err =~ s/\s+/ /g;
	$err =~ s/^ | $//g;
	return ($config, $err);
}

# The CredHub name inside a ((name)) reference.
sub ref_name {
	my ($ref) = @_;
	return ($ref // '') =~ /^\(\((.*)\)\)$/ ? $1 : '';
}

sub dump_json {
	return JSON::PP->new->canonical->allow_nonref->allow_blessed->encode($_[0]);
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

	# BOSH splits a ((name.subkey)) reference on its first dot, so Genesis
	# flattens everything outside [A-Za-z0-9_-] in the stored credential name:
	# the property path pve.host is entombed as cpi-config-property--pve_host.
	# The sha still covers the unflattened path.
	for my $path (sort keys %secret_source_for) {
		my $value = at_path($config, $path);
		(my $safe_name = $path) =~ s/[^A-Za-z0-9_-]/_/g;
		like(
			$value, qr{^\(\(/cpi-config/properties/cpi-config-property--\Q$safe_name\E--[0-9a-f]{8}\)\)$},
			"$path is a credhub reference, not the raw value",
		);
		unlike($value, qr/\./, "and the reference carries no dot for BOSH to split on");
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

# --- an env-file literal credential is entombed ------------------------
subtest 'an env-file literal pve_api_token is entombed, not passed through' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		my $hook = $build->(cpi => { %BASE_CPI });
		my ($config, $err) = try_gather($hook);
		is($err, '', "$label: renders");
		my $ref = at_path($config, 'pve.api_token') // '';
		like($ref, qr{^\(\(\Q$prefix\Ecpi-config-property--pve_api_token--[0-9a-f]{8}\)\)$},
			"$label: pve.api_token is a reference into the destination's CredHub");
		is($hook->{credhub_secrets}{ref_name($ref)}, $TOKEN, "$label: the token is handed to CredHub under that name");
		ok(!exists $config->{pve_api_token}, "$label: and is not duplicated at the top level");
		unlike(dump_json($config), qr/\Q$TOKEN\E/, "$label: the token appears nowhere in the config");
	}
};

# --- the credential entries in the map ---------------------------------
subtest 'both credentials are optional secrets in the pve map' => sub {
	my %entry = map {
		my ($secret, $key, undef, $default, $optional) =
			$_ =~ /^(!?)([^\@:\?\>]+)(?:\@([^:\?\>]+))?(?:(?::([^>]+))|(\?))?(?:>(.+))?$/;
		($key => { secret => $secret, default => $default, optional => $optional })
	} Test::FakeCpiConfig->_property_map_for_pve;
	for my $key (qw/pve_password pve_api_token/) {
		is($entry{$key}{secret}, '!', "$key is marked ! so the hook entombs it");
		is($entry{$key}{optional}, '?', "$key is marked ? so an absent value is omitted");
		ok(!defined $entry{$key}{default}, "$key declares no default, so token mode cannot get an empty password");
	}
};

# --- the map itself is well-formed -------------------------------------
subtest 'every pve map entry declares an explicit output path' => sub {
	my @map = Test::FakeCpiConfig->_property_map_for_pve;
	is(scalar(@map), 18, 'the pve map has 18 entries');

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
	# pve.api_token and pve.password are optional, and a render carries
	# exactly one of them, so neither is in the default-render expectations
	# above, but the map must still declare both.
	is_deeply(
		[sort keys %paths],
		[sort (keys %EXPECTED_SPEC_PATHS, 'pve.api_token', 'pve.password')],
		'the map targets exactly the jobs/pve_cpi/spec property set it claims to',
	);
};

# --- agent.mbus defaults to the NATS of the director owning the agent ---
#
# An empty agent.mbus fails every create_vm under a NATS-mTLS director, which
# sends the CPI a client cert but no URL. The two cpi configs this hook feeds
# name different directors, so one default cannot serve both.
subtest 'agent.mbus defaults per cpi config to the director that owns the agent' => sub {
	my %cpi = (
		pve_host => '10.115.16.1', pve_user => 'ocfp-cpi@pve', pve_node => 'lab-pipes-0',
		pve_api_token => $TOKEN,
	);

	# Own-director config: Genesis builds it with its default director prefix,
	# because the references must resolve against the new director's own
	# Credhub. That director manages the agents, so they reach it at this
	# environment's own static_ip.
	my $own = build_hook_for(
		cpi             => \%cpi,
		params          => { static_ip => '10.115.20.64' },
		credhub_prefix  => $DIRECTOR_PREFIX,
		director_exodus => { url => 'https://10.115.16.4:25555' },
	)->gather_properties_for_pve;
	is(
		at_path($own, 'agent.mbus'), 'nats://10.115.20.64:4222',
		"the director this environment deploys gets its own NATS, not its parent's",
	);

	# Child config: Genesis builds it with the environment's cpi_credhub_base
	# so the PARENT can resolve the references. The parent builds this
	# environment's director VM, so that VM's agent reports to the parent.
	my $child = build_hook_for(
		cpi             => \%cpi,
		params          => { static_ip => '10.115.20.64' },
		credhub_prefix  => $CHILD_PREFIX,
		director_exodus => { url => 'https://10.115.16.4:25555' },
	)->gather_properties_for_pve;
	is(
		at_path($child, 'agent.mbus'), 'nats://10.115.16.4:4222',
		"the parent director's config points the new director's agent back at the parent",
	);
};

subtest 'an explicit pve_agent_mbus is never overwritten by the default' => sub {
	my %cpi = (
		pve_host => '10.115.16.1', pve_user => 'ocfp-cpi@pve', pve_node => 'lab-pipes-0',
		pve_api_token => $TOKEN,
		pve_agent_mbus => 'nats://10.115.99.9:4222',
	);

	for my $case (
		['own-director', $DIRECTOR_PREFIX],
		['child',        $CHILD_PREFIX],
	) {
		my ($label, $prefix) = @$case;
		my $config = build_hook_for(
			cpi             => \%cpi,
			params          => { static_ip => '10.115.20.64' },
			credhub_prefix  => $prefix,
			director_exodus => { url => 'https://10.115.16.4:25555' },
		)->gather_properties_for_pve;
		is(
			at_path($config, 'agent.mbus'), 'nats://10.115.99.9:4222',
			"the operator's explicit value survives in the $label config",
		);
	}
};

# --- the parent's placement authority governs the child director's VM ---
#
# The parent director's CPI records the VM it builds for this environment's
# director in the parent's own allocation journal, where only the parent's
# namespace is enrolled. The CPI honours pve_storage_placement_namespace as a
# per-request override, so a child namespace in the child config sent create_vm
# after a journal entry that does not exist:
#   statat <sha256(child namespace)>: no such file or directory
# The journal directory is process-level policy and never an override at all.
subtest 'the child config carries neither placement namespace nor journal dir' => sub {
	my %cpi = (
		pve_host => '10.115.16.1', pve_user => 'ocfp-cpi@pve', pve_node => 'lab-pipes-0',
		pve_api_token => $TOKEN,
		pve_storage_placement_namespace    => 'ocfp-cf1-lab-ocf',
		pve_storage_allocation_journal_dir => '/var/vcap/store/pve_cpi/allocations',
		pve_storage_sets => {
			ephemeral => {
				names    => ['pvuproxcf1_ns_1', 'pvuproxcf1_ns_2'],
				strategy => { name => 'weighted_free_space' },
			},
		},
		pve_ephemeral_storage_set => 'ephemeral',
	);
	my %common = (
		cpi             => \%cpi,
		params          => { static_ip => '10.115.20.64' },
		director_exodus => { url => 'https://10.115.16.4:25555' },
	);

	my $child = build_hook_for(%common, credhub_prefix => $CHILD_PREFIX)->gather_properties_for_pve;
	ok(!exists $child->{pve_storage_placement_namespace},
		"the child config hands the parent no namespace, so the parent's own enrolled one governs");
	ok(!exists $child->{pve_storage_allocation_journal_dir},
		'the child config hands the parent no journal directory');
	ok(!exists $child->{pve}{storage_placement_namespace} && !exists $child->{pve}{storage_allocation_journal_dir},
		'and neither key reaches the parent in its nested pve.* form');
	is_deeply($child->{pve_storage_sets}, $cpi{pve_storage_sets},
		'the storage sets still pass through to the parent unchanged');
	is($child->{pve_ephemeral_storage_set}, 'ephemeral',
		'the ephemeral storage-set binding still passes through to the parent');

	my $own = build_hook_for(%common, credhub_prefix => $DIRECTOR_PREFIX)->gather_properties_for_pve;
	is($own->{pve_storage_placement_namespace}, 'ocfp-cf1-lab-ocf',
		"the own-director config still carries this director's namespace");
	is($own->{pve_storage_allocation_journal_dir}, '/var/vcap/store/pve_cpi/allocations',
		"the own-director config still carries this director's journal directory");
};

subtest 'a nested pve.* placement namespace is dropped from the child config too' => sub {
	my %cpi = (
		pve_host => '10.115.16.1', pve_user => 'ocfp-cpi@pve', pve_node => 'lab-pipes-0',
		pve_api_token => $TOKEN,
		pve => {
			storage_placement_namespace    => 'ocfp-cf1-lab-ocf',
			storage_allocation_journal_dir => '/var/vcap/store/pve_cpi/allocations',
		},
	);
	my %common = (
		cpi             => \%cpi,
		params          => { static_ip => '10.115.20.64' },
		director_exodus => { url => 'https://10.115.16.4:25555' },
	);

	my $child = build_hook_for(%common, credhub_prefix => $CHILD_PREFIX)->gather_properties_for_pve;
	ok(!exists $child->{pve}{storage_placement_namespace},
		'the nested namespace does not reach the parent');
	ok(!exists $child->{pve}{storage_allocation_journal_dir},
		'the nested journal directory does not reach the parent');
	ok(defined $child->{pve}{host}, 'the rest of the nested pve block is left in place');

	my $own = build_hook_for(%common, credhub_prefix => $DIRECTOR_PREFIX)->gather_properties_for_pve;
	is($own->{pve}{storage_placement_namespace}, 'ocfp-cf1-lab-ocf',
		'the own-director config keeps the nested namespace');
};

# --- kit-consumed keys never become CPI context overrides --------------
subtest 'keys the kit consumes itself are not passed through to the CPI' => sub {
	my %kit_keys = (
		pve_host_operator    => 'lab-lm-0.tail1234.ts.net',
		pve_disk_format      => 'qcow2',
		pve_bosh_cpu         => 4,
		pve_bosh_ram         => 8192,
		pve_bosh_disk        => 65536,
		pve_compilation_cpu  => 4,
		pve_compilation_ram  => 8192,
		pve_compilation_disk => 65536,
	);
	my %cpi = (%BASE_CPI, %kit_keys, pve_vm_disk_format => 'qcow2', pve_log_level => 'debug');

	for my $prefix ($DIRECTOR_PREFIX, $CHILD_PREFIX) {
		my $hook = build_hook_for(
			cpi             => {%cpi},
			params          => { static_ip => '10.115.20.64' },
			director_exodus => { url => 'https://10.115.16.4:25555' },
			credhub_prefix  => $prefix,
		);
		my $config = $hook->gather_properties_for_pve;
		my $which = $prefix eq $DIRECTOR_PREFIX ? 'own-director' : 'child';

		for my $key (sort keys %kit_keys) {
			ok(!exists $config->{$key}, "$which config has no top-level $key");
			(my $nested = $key) =~ s/^pve_//;
			ok(!exists $config->{pve}{$nested}, "$which config has no pve.$nested");
		}
		is(at_path($config, 'pve.vm_disk_format'), 'qcow2', "$which config still maps pve.vm_disk_format");
		is($config->{pve_log_level}, 'debug', "$which config still passes an unmodelled spec key through");

		# hooks/cloud-config.pm reads disk_types disk_format from this env key,
		# so dropping it from the cpi config must leave the env's copy alone.
		is(scalar($hook->env->lookup('bosh-configs.cpi.pve_disk_format', 'raw')), 'qcow2',
			"$which build leaves bosh-configs.cpi.pve_disk_format for the cloud config");
		is(scalar($hook->env->lookup('bosh-configs.cpi.pve_host_operator')), 'lab-lm-0.tail1234.ts.net',
			"$which build leaves bosh-configs.cpi.pve_host_operator for create-env");
	}
};

subtest 'a nested pve.* form of a kit-consumed key is dropped too' => sub {
	for my $prefix ($DIRECTOR_PREFIX, $CHILD_PREFIX) {
		my $which = $prefix eq $DIRECTOR_PREFIX ? 'own-director' : 'child';
		my $hook = build_hook_for(
			cpi => {
				%BASE_CPI,
				pve => { disk_format => 'qcow2', host_operator => 'lab-lm-0.tail1234.ts.net' },
			},
			params          => { static_ip => '10.115.20.64' },
			director_exodus => { url => 'https://10.115.16.4:25555' },
			credhub_prefix  => $prefix,
		);
		my ($config, $warned) = (undef, '');
		{
			open(my $saved, '>&', \*STDERR) or die "cannot dup STDERR: $!";
			close STDERR;
			open(STDERR, '>', \$warned) or die "cannot capture STDERR: $!";
			$config = eval { $hook->gather_properties_for_pve };
			my $died = $@;
			close STDERR;
			open(STDERR, '>&', $saved) or die "cannot restore STDERR: $!";
			die $died if $died;
		}
		$warned =~ s{\e\[[0-9;]*m}{}g;

		ok(!exists $config->{pve}{disk_format}, "$which: nested pve.disk_format is dropped");
		ok(!exists $config->{pve}{host_operator}, "$which: nested pve.host_operator is dropped");
		ok(defined $config->{pve}{host}, "$which: the rest of the nested pve block is left in place");
		like($warned, qr/Ignoring\s+bosh-configs\.cpi\.pve\.disk_format.*flat\s+bosh-configs\.cpi\.pve_disk_format/s,
			"$which: the dropped pve.disk_format is reported, naming the flat key");
		like($warned, qr/Ignoring\s+bosh-configs\.cpi\.pve\.host_operator/, "$which: and so is pve.host_operator");
	}
};

# --- PVE credentials ---------------------------------------------------
#
# The cpi config used to carry pve.api_token and pve.password in cleartext,
# on both destinations, because the map left them unmarked. Each case below
# runs for the own-director config and for the parent copy.

my $VAULT_PATH = '/secret/config/lab/mgmt/cpi/pve';

# Assert one destination entombed exactly $value under $path and nothing
# else of the credential pair.
sub entombs_only {
	my ($label, $prefix, $hook, $config, $path, $value) = @_;
	(my $safe = $path) =~ s/[^A-Za-z0-9_-]/_/g;
	my $ref = at_path($config, $path) // '';
	like($ref, qr{^\(\(\Q$prefix\Ecpi-config-property--\Q$safe\E--[0-9a-f]{8}\)\)$},
		"$label: $path is a reference into the destination's CredHub");
	is($hook->{credhub_secrets}{ref_name($ref)}, $value, "$label: the credential is handed to CredHub under that name");
	my $other = $path eq 'pve.api_token' ? 'pve.password' : 'pve.api_token';
	(my $leaf = $other) =~ s/^pve\.//;
	ok(!exists $config->{pve}{$leaf}, "$label: $other is not emitted");
	is(scalar(grep { /--pve_\Q$leaf\E--/ } keys %{$hook->{credhub_secrets}}), 0,
		"$label: nothing is entombed for $other");
	unlike(dump_json($config), qr/\Q$value\E/, "$label: the credential appears nowhere in the config");
}

subtest 'token mode entombs the token and omits the password' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		my $hook = $build->(vault => { %VAULT_BASE, api_token => $TOKEN });
		my ($config, $err) = try_gather($hook);
		is($err, '', "$label: renders");
		entombs_only($label, $prefix, $hook, $config, 'pve.api_token', $TOKEN);
	}
};

subtest 'password mode entombs the password and omits the token' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		my $hook = $build->(vault => { %VAULT_BASE, password => $PASSWORD });
		my ($config, $err) = try_gather($hook);
		is($err, '', "$label: renders");
		entombs_only($label, $prefix, $hook, $config, 'pve.password', $PASSWORD);
	}
};

subtest 'a stale empty placeholder in vault counts as absent' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;

		my $hook = $build->(vault => { %VAULT_BASE, api_token => $TOKEN, password => '' });
		my ($config, $err) = try_gather($hook);
		is($err, '', "$label: a token beside password: \"\" renders");
		entombs_only("$label, token", $prefix, $hook, $config, 'pve.api_token', $TOKEN);

		$hook = $build->(vault => { %VAULT_BASE, password => $PASSWORD, api_token => '' });
		($config, $err) = try_gather($hook);
		is($err, '', "$label: a password beside api_token: \"\" renders");
		entombs_only("$label, password", $prefix, $hook, $config, 'pve.password', $PASSWORD);
	}
};

subtest 'two non-empty credentials refuse to render and name both sources' => sub {
	my @cases = (
		['vault token and vault password',
			{ vault => { %VAULT_BASE, api_token => $TOKEN, password => $PASSWORD } },
			"$VAULT_PATH:api_token", "$VAULT_PATH:password"],
		['env-file token and vault password',
			{ cpi => { pve_api_token => $TOKEN }, vault => { %VAULT_BASE, password => $PASSWORD } },
			'bosh-configs.cpi.pve_api_token', "$VAULT_PATH:password"],
		['vault token and env-file password',
			{ cpi => { pve_password => $PASSWORD }, vault => { %VAULT_BASE, api_token => $TOKEN } },
			"$VAULT_PATH:api_token", 'bosh-configs.cpi.pve_password'],
	);
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		for my $case (@cases) {
			my ($what, $opts, $token_source, $password_source) = @$case;
			my ($config, $err) = try_gather($build->(%$opts));
			ok(!defined $config, "$label, $what: nothing is returned to upload");
			like($err, qr/both/i, "$label, $what: the hook says both credentials are set");
			like($err, qr/\Q$token_source\E/, "$label, $what: and names the token's source");
			like($err, qr/\Q$password_source\E/, "$label, $what: and names the password's source");
		}
	}
};

subtest 'an env-file null clears a vault credential' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		my $hook = $build->(
			cpi   => { pve_password => undef },
			vault => { %VAULT_BASE, api_token => $TOKEN, password => $PASSWORD },
		);
		my ($config, $err) = try_gather($hook);
		is($err, '', "$label: renders");
		entombs_only($label, $prefix, $hook, $config, 'pve.api_token', $TOKEN);
	}
};

subtest 'no credential at all refuses to render' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		my ($config, $err) = try_gather($build->(cpi => { %NO_CREDENTIAL_CPI }));
		ok(!defined $config, "$label: nothing is returned to upload");
		like($err, qr/pve\.api_token/, "$label: the message names pve.api_token");
		like($err, qr/pve\.password/, "$label: the message names pve.password");
		like($err, qr/\Q$VAULT_PATH\E/, "$label: the message names the vault path");
	}
};

subtest 'vault passwords that look like JSON are entombed exactly' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		for my $password ('null', '"quoted"', 'true', 'false', '1.0', '1e3', '[1]') {
			my $hook = $build->(vault => { %VAULT_BASE, password => $password });
			my ($config, $err) = try_gather($hook);
			is($err, '', "$label: the vault password $password renders");
			my ($stored) = map { $hook->{credhub_secrets}{$_} } grep { /--pve_password--/ } keys %{$hook->{credhub_secrets}};
			is($stored, $password, "$label: the vault password $password is entombed as that exact string");
		}

		my ($config, $err) = try_gather($build->(vault => { %VAULT_BASE, password => '0' }));
		ok(!defined $config, "$label: the vault password 0 does not render");
		like($err, qr/"0"/, "$label: and the message says why 0 is refused");
	}
};

subtest 'a vault password shaped like a BOSH reference is refused' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		my $hook = $build->(vault => { %VAULT_BASE, password => '((opaque-password))' });
		my ($config, $err) = try_gather($hook);
		ok(!defined $config, "$label: nothing is returned to upload");
		like($err, qr/\Q$VAULT_PATH\E:password/, "$label: the message names the vault path");
		is(scalar(grep { /--pve_password--/ } keys %{$hook->{credhub_secrets}}), 0,
			"$label: no pve_password entry is entombed");
		is(scalar(grep { $_ eq '((opaque-password))' } values %{$hook->{credhub_secrets}}), 0,
			"$label: and the reference-shaped value is not stored either");

		# An env-file reference is the documented way to point at a value
		# already in CredHub, so it passes through as written.
		$hook = $build->(cpi => { pve_password => '((/x/pve-password))' }, vault => { %VAULT_BASE });
		($config, $err) = try_gather($hook);
		is($err, '', "$label: an env-file ((/x/pve-password)) renders");
		is(at_path($config, 'pve.password'), '((/x/pve-password))', "$label: and passes through unchanged");
		is(scalar(grep { /--pve_password--/ } keys %{$hook->{credhub_secrets}}), 0,
			"$label: with nothing entombed for it");
	}
};

subtest 'each destination reads the credential through its own lookup' => sub {
	my $self_token   = 'kit-test@pve!self=11111111-1111-1111-1111-111111111111';
	my $parent_token = 'kit-test@pve!parent=22222222-2222-2222-2222-222222222222';
	my %raw = (pve_api_token => '(( vault "secret/x:api_token" ))', pve_agent_mbus => 'nats://10.115.16.4:4222');
	my %common = (
		cpi           => { %raw },
		entombed_self => { %raw, pve_api_token => $self_token },
		entombed      => { %raw, pve_api_token => $parent_token },
		vault         => { %VAULT_BASE },
	);

	my $own = own_hook(%common);
	my ($config, $err) = try_gather($own);
	is($err, '', 'own-director: renders');
	entombs_only('own-director', $DIRECTOR_PREFIX, $own, $config, 'pve.api_token', $self_token);
	is(scalar(grep { !/^self:/ } @{$own->env->{calls}}), 0, 'own-director: only lookup_entombed_self was read');
	is(scalar(grep { !/^self:/ } @{$own->env->{credhub_writes}}), 0,
		"own-director: only the director's own CredHub was written by the entombed build");

	my $parent = parent_hook(%common);
	($config, $err) = try_gather($parent);
	is($err, '', 'parent copy: renders');
	entombs_only('parent copy', $CHILD_PREFIX, $parent, $config, 'pve.api_token', $parent_token);
	is(scalar(grep { !/^parent:/ } @{$parent->env->{calls}}), 0, 'parent copy: only lookup_entombed was read');
	is(scalar(grep { !/^parent:/ } @{$parent->env->{credhub_writes}}), 0,
		"parent copy: only the parent's CredHub was written by the entombed build");
};

subtest 'an env-file credential YAML parsed as a non-scalar is refused' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		for my $case (
			['a hash',    { value => $PASSWORD }],
			['an array',  [$PASSWORD]],
			['a boolean', JSON::PP::true()],
		) {
			my ($what, $value) = @$case;
			my ($config, $err) = try_gather($build->(cpi => { pve_password => $value }, vault => { %VAULT_BASE }));
			ok(!defined $config, "$label: $what does not render");
			like($err, qr/bosh-configs\.cpi\.pve_password/, "$label: the message names the key");
			like($err, qr/quote/i, "$label: and asks for the value to be quoted");
		}
	}
};

# A block given as an expression is one leaf named pve, which matches no map
# entry, so the override pass copies its evaluated value in without the
# resolver ever seeing it. With the nulls clearing the vault credentials, the
# selection check sees one credential and passes; only the final check on
# the returned tree can catch the plaintext.
sub block_expression_hook {
	my ($build, $pve_props) = @_;
	my %raw = (
		pve_password   => undef,
		pve_api_token  => undef,
		pve_agent_mbus => 'nats://10.115.16.4:4222',
		pve            => '(( grab params.pve_props ))',
	);
	return $build->(
		cpi       => { %raw },
		evaluated => { %raw, pve => $pve_props },
		vault     => { %VAULT_BASE, api_token => $TOKEN },
	);
}

subtest 'a credential supplied by a block expression is refused' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		for my $case (
			['pve.password',  { password  => $PASSWORD }, $PASSWORD],
			['pve.api_token', { api_token => 'SYNTHETIC-TOKEN' }, 'SYNTHETIC-TOKEN'],
		) {
			my ($path, $props, $secret) = @$case;
			my ($config, $err) = try_gather(block_expression_hook($build, $props));
			ok(!defined $config, "$label: a $path from the block is not returned");
			like($err, qr/\Q$path\E/, "$label: the message names $path");
			unlike(dump_json($config), qr/\Q$secret\E/, "$label: the synthetic value appears in no returned config");
		}
	}
};

subtest 'a hash or array at a credential path is refused' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		for my $case (
			['pve.password',  { password  => { value => $PASSWORD } }],
			['pve.api_token', { api_token => ['SYNTHETIC-TOKEN'] }],
			['pve.password',  { password  => { value => '((/x/p))' } }],
		) {
			my ($path, $props) = @$case;
			my ($config, $err) = try_gather(block_expression_hook($build, $props));
			ok(!defined $config, "$label: a non-scalar $path is not returned");
			like($err, qr/\Q$path\E/, "$label: the message names $path");
		}
	}
};

subtest 'other plaintext credentials from the passthrough are refused' => sub {
	my %whole_block = (
		pve_host       => '10.115.16.1',
		pve_user       => 'ocfp-cpi@pve',
		pve_node       => 'lab-pipes-0',
		pve_agent_mbus => 'nats://10.115.16.4:4222',
	);
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		my @refused = (
			['pve.lb_register.password',
				{ cpi => { %BASE_CPI, pve => { lb_register => { password => 'SYNTHETIC-LB-PASSWORD' } } } }],
			['pve_password',
				{ cpi => '(( grab params.cpi_block ))', evaluated => { %whole_block, pve_password => $PASSWORD } }],
			['pve_api_token',
				{ cpi => '(( grab params.cpi_block ))', evaluated => { %whole_block, pve_api_token => 'SYNTHETIC-TOKEN' } }],
			['agent.mbus',
				{ cpi => { %BASE_CPI, pve_agent_mbus => 'nats://u:plain@10.0.0.4:4222' } }],
		);
		for my $case (@refused) {
			my ($path, $opts) = @$case;
			my ($config, $err) = try_gather($build->(vault => { %VAULT_BASE }, %$opts));
			ok(!defined $config, "$label: a plaintext $path is not returned");
			like($err, qr/(?<![\w.])\Q$path\E(?![\w.])/, "$label: the message names $path");
		}

		my @accepted = (
			['pve.lb_register.password', '((/x/lb-password))',
				{ cpi => { %BASE_CPI, pve => { lb_register => { password => '((/x/lb-password))' } } } }],
			['agent.mbus', 'nats://u:((/x/nats-password))@10.0.0.4:4222',
				{ cpi => { %BASE_CPI, pve_agent_mbus => 'nats://u:((/x/nats-password))@10.0.0.4:4222' } }],
		);
		for my $case (@accepted) {
			my ($path, $value, $opts) = @$case;
			my ($config, $err) = try_gather($build->(%$opts));
			is($err, '', "$label: a referenced $path renders");
			is(at_path($config, $path), $value, "$label: and $path passes through unchanged");
		}

		my %raw = (%BASE_CPI, pve => '(( grab params.pve_props ))');
		my ($config, $err) = try_gather($build->(cpi => { %raw }, evaluated => { %raw, pve => { vm_storage => 'nfs-e' } }));
		is($err, '', "$label: a block expression that supplies only vm_storage renders");
	}
};

subtest 'storage-set names that look like credentials are accepted' => sub {
	my %set = (names => ['nfs-e'], strategy => { name => 'spread', version => 1 });
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		for my $name (qw/secret api_token/) {
			my $sets = { $name => { %set } };
			my ($config, $err) = try_gather($build->(cpi => { %BASE_CPI, pve_storage_sets => $sets }));
			is($err, '', "$label: a storage set named $name renders");
			is_deeply($config->{pve_storage_sets}, $sets, "$label: and passes through unchanged");
		}

		my %raw = (%BASE_CPI, pve => '(( grab params.pve_props ))');
		my $nested = { storage_sets => { password => { %set } } };
		my ($config, $err) = try_gather($build->(cpi => { %raw }, evaluated => { %raw, pve => $nested }));
		is($err, '', "$label: a nested storage set named password, from a block expression, renders");
		is_deeply(at_path($config, 'pve.storage_sets'), $nested->{storage_sets}, "$label: and passes through unchanged");
	}
};

subtest 'unknown credential-named properties are refused' => sub {
	for my $dest (@DESTINATIONS) {
		my ($label, $prefix, $build) = @$dest;
		for my $case (
			['pve_proxy_password', { %BASE_CPI, pve_proxy_password => 'SYNTHETIC-PROXY' }],
			['pve.proxy_secret',   { %BASE_CPI, pve => { proxy_secret => 'SYNTHETIC-PROXY' } }],
		) {
			my ($path, $cpi) = @$case;
			my ($config, $err) = try_gather($build->(cpi => $cpi));
			ok(!defined $config, "$label: a literal $path is not returned");
			like($err, qr/\Q$path\E/, "$label: the message names $path");
		}
	}
};

subtest 'the credential paths cover every CPI credential setter' => sub {
	my $fixture = "$FindBin::Bin/fixtures/pve_cpi-credential-setters.txt";
	open(my $fh, '<', $fixture) or die "cannot read $fixture: $!";
	my @setters = grep { !/^\s*(#|$)/ } map { chomp; $_ } <$fh>;
	close $fh;
	is_deeply([sort @setters], [qw/pve_api_token pve_password/], 'the fixture lists the CPI credential setters');

	my %paths = map { ($_ => 1) } Genesis::Hook::CpiConfig::BOSH::pve_credential_paths();
	for my $setter (@setters) {
		(my $nested = $setter) =~ s/^pve_/pve./;
		ok($paths{$setter}, "the flat $setter is a credential path");
		ok($paths{$nested}, "the nested $nested is a credential path");
	}
};

subtest 'a Genesis without destination-aware lookups is refused' => sub {
	my $expect = qr/Genesis/;
	{
		no warnings 'redefine';
		local *Genesis::Hook::CpiConfig::_resolve;
		my ($config, $err) = try_gather(own_hook(cpi => { %BASE_CPI }));
		ok(!defined $config, 'without _resolve, nothing renders');
		like($err, qr/Genesis::Hook::CpiConfig::_resolve/, 'and the message names what is missing');
	}
	{
		no warnings 'redefine';
		local *Genesis::Hook::CpiConfig::_lookup_operator_value;
		my ($config, $err) = try_gather(own_hook(cpi => { %BASE_CPI }));
		ok(!defined $config, 'with _resolve but without _lookup_operator_value, nothing renders');
		like($err, qr/_lookup_operator_value/, 'and the message names what is missing');
	}
	{
		my $hook = Test::FakeCpiConfig->new(env => Test::FakeEnvWithoutLookupEntombed->new, self_upload => 1);
		my ($config, $err) = try_gather($hook);
		ok(!defined $config, 'with an env that has no lookup_entombed, nothing renders');
		like($err, qr/lookup_entombed\b/, 'and the message names what is missing');
	}
};

done_testing;
