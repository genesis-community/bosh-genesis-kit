#!/usr/bin/env perl
# Unit tests for the pve CPI-release parameter migration check in
# hooks/check.pm.
#
# The kit used to build the bosh-proxmox-cpi release entry from a local dev
# tarball: params.pve_cpi_release_path was joined onto a literal file://
# prefix in overlay/cpis/pve-base.yml. That entry now takes a full URL
# (params.pve_cpi_release_url) and defaults to the published GitHub
# release, so a leftover pve_cpi_release_path is silently inert -- the
# env would deploy the default release instead of the dev tarball it
# names, with nothing in the manifest to show for it.
#
# spec/spec.t cannot cover this: `genesis check` runs the hook, but the
# check has to observe a param that no longer participates in any merge,
# and the failure mode under test is precisely "renders fine, means
# something else". So this file loads the real hook module and drives
# check_environment_parameters against thin doubles for the env-side
# collaborators; the kit's own branch runs unmodified.
#
# Required cases:
#   (a) iaas=pve with a leftover params.pve_cpi_release_path -> the check
#       fails and names both the old and the new param, so the operator
#       gets a migration instruction rather than a silent default swap.
#   (b) iaas=pve without it -> the check passes (the defaults path is the
#       normal case and must not warn).
#   (c) a non-pve iaas with the same leftover param is untouched -- the
#       guard is scoped to the CPI that owns the param.
#   (d) a pinned bosh-proxmox-cpi older than 0.9.4 fails.  The kit's cpi
#       configs rely on 0.9.4 applying the credential keys as a group; an
#       older CPI lets an omitted credential inherit the job's own, which
#       on a parent director is the parent's.  A +dev build cannot be
#       compared, so it passes with a warning, and no pin passes.
#   (e) an inline bosh-configs.director-cpi.cpis entry of type pve holds no
#       credential except through a single (( vault "..." )) call or an
#       absolute ((/...)) CredHub reference.  Genesis uploads that block as
#       it resolves, without the cpi-config hook, so any other expression,
#       such as (( grab params.pve_api_token )), would store the credential
#       in plaintext.  The check reads the unevaluated env, because the
#       evaluated one holds the literal token even for a valid (( vault )).
use strict;
use warnings;
use FindBin;
use Test::More;

my $hook_file = "$FindBin::Bin/../../hooks/check.pm";
require $hook_file;

# --- Test doubles ------------------------------------------------------

package Test::FakeKit;

sub new  { return bless {}, shift }
sub path { my ($self, $file) = @_; return "$FindBin::Bin/../../$file" }

package Test::FakeEnv;

# data is the evaluated view behind lookup, where every (( vault )) and
# (( grab )) has become its literal result.  raw is the unevaluated env
# behind lookup_unevaled, which still holds the expressions.  A check that
# reads the wrong view fails the vault-expression cases below.
sub new {
	my ($class, %opts) = @_;
	return bless { data => $opts{data} // {}, raw => $opts{raw} // {} }, $class;
}

sub kit { return Test::FakeKit->new }

sub lookup          { my ($self, @args) = @_; return _walk($self->{data}, @args) }
sub lookup_unevaled { my ($self, @args) = @_; return _walk($self->{raw}, @args) }

# Minimal stand-in for Genesis::Env::lookup: dotted-path traversal over a
# plain hash, returning $default when any segment is missing.
sub _walk {
	my ($node, $key, $default) = @_;
	my @path = split /\./, $key;
	for my $seg (@path) {
		return $default unless ref($node) eq 'HASH' && exists $node->{$seg};
		$node = $node->{$seg};
	}
	return $node;
}

sub has_feature { return 0 }

package Test::FakeCheck;

# Inherit the real hook module under test -- check_environment_parameters
# is NOT overridden here, so the kit's own code runs. Only the
# Genesis-side collaborators (env, iaas, is_ocfp, result reporting) are
# replaced.
our @ISA = ('Genesis::Hook::Check::BOSH');

sub new {
	my ($class, %opts) = @_;
	return bless {
		env     => Test::FakeEnv->new(data => $opts{data}, raw => $opts{raw}),
		iaas    => $opts{iaas},
		is_ocfp => $opts{is_ocfp} // 0,
		results => [],
	}, $class;
}

sub env     { $_[0]{env} }
sub iaas    { $_[0]{iaas} }
sub is_ocfp { $_[0]{is_ocfp} }

sub start_check { return 1 }

# Genesis::Hook::Check::check_result returns false only for a failure (or
# an error), so a warning still passes; record what was reported so the
# tests can assert on the message the operator actually sees.
sub check_result {
	my ($self, $check, $status, $msg) = @_;
	$status //= 'ok';
	push @{ $self->{results} }, { check => $check, status => $status, msg => $msg // '' };
	return ($status eq 'failed' || $status eq 'error') ? 0 : 1;
}

sub results { @{ $_[0]{results} } }

sub has_entry { return 1 }

package main;

# (a) leftover pve_cpi_release_path on a pve env is a hard failure that
#     names the replacement param.
{
	my $check = Test::FakeCheck->new(
		iaas => 'pve',
		data => { params => { pve_cpi_release_path => '/tmp/bosh-pve-cpi-dev.tgz' } },
	);
	my $ok = $check->check_environment_parameters();
	ok(!$ok, 'pve env with pve_cpi_release_path fails the environment check');

	my ($result) = grep { $_->{status} eq 'failed' } $check->results;
	ok($result, 'a failed result is reported');
	like($result->{msg}, qr/pve_cpi_release_path/,
		'message names the obsolete param');
	like($result->{msg}, qr/pve_cpi_release_url/,
		'message names the replacement param');
}

# (b) the defaults path -- no release params at all -- passes.
{
	my $check = Test::FakeCheck->new(
		iaas => 'pve',
		data => { params => { pve_host => 'test-pve-host' } },
	);
	ok($check->check_environment_parameters(),
		'pve env without pve_cpi_release_path passes');
	is(scalar(grep { $_->{status} eq 'failed' } $check->results), 0,
		'nothing is reported as failed');
}

# (c) the guard is scoped to pve; another iaas with the same key is not
#     the kit's business.
{
	my $check = Test::FakeCheck->new(
		iaas => 'openstack',
		data => { params => { pve_cpi_release_path => '/tmp/bosh-pve-cpi-dev.tgz' } },
	);
	ok($check->check_environment_parameters(),
		'non-pve env with the same param is unaffected');
}

# (d) the bosh-proxmox-cpi version guard.
for my $version (qw/0.9.3 0.8.0/) {
	my $check = Test::FakeCheck->new(
		iaas => 'pve',
		data => { params => { pve_cpi_release_version => $version } },
	);
	ok(!$check->check_environment_parameters(), "pve env pinned to bosh-proxmox-cpi $version fails");
	my ($result) = grep { $_->{status} eq 'failed' } $check->results;
	like($result ? $result->{msg} : '', qr/0\.9\.4/, "and the message for $version names 0.9.4");
	like($result ? $result->{msg} : '', qr/\Q$version\E/, "and names the pinned $version");
}

for my $version (qw/0.9.4 0.9.5/) {
	my $check = Test::FakeCheck->new(
		iaas => 'pve',
		data => { params => { pve_cpi_release_version => $version } },
	);
	ok($check->check_environment_parameters(), "pve env pinned to bosh-proxmox-cpi $version passes");
	is(scalar(grep { $_->{status} ne 'ok' } $check->results), 0, "with nothing reported for $version");
}

{
	my $check = Test::FakeCheck->new(
		iaas => 'pve',
		data => { params => { pve_cpi_release_version => '0+dev.1' } },
	);
	ok($check->check_environment_parameters(), 'pve env pinned to a +dev build passes');
	my ($result) = grep { $_->{status} eq 'warning' } $check->results;
	ok($result, 'with a warning');
	like($result ? $result->{msg} : '', qr/6953b44b/, 'that names the CPI commit the build must include');
}

{
	my $check = Test::FakeCheck->new(iaas => 'pve', data => { params => {} });
	ok($check->check_environment_parameters(), 'pve env without a pin passes on the kit default');
	is(scalar(grep { $_->{status} ne 'ok' } $check->results), 0, 'with nothing reported');
}

# (e) the inline director-cpi allowlist.
my $VAULT_TOKEN = '(( vault "secret/x:api_token" ))';
my $ABS_TOKEN   = '((/cpi-config/properties/pve-api-token-az1))';
my %HOST        = (host => '10.0.0.1', user => 'kit-test@pve', node => 'pve-unit-0');
my %SET         = (names => ['nfs-e'], strategy => { name => 'spread', version => 1 });

# Runs the environment check with bosh-configs.director-cpi.cpis set to $raw
# in the unevaluated env and to $evaluated (default: $raw) in the evaluated
# one, and returns whether it passed and what it reported as failed.
sub inline_check {
	my ($raw, $evaluated) = @_;
	my $wrap = sub { +{ 'bosh-configs' => { 'director-cpi' => { cpis => $_[0] } } } };
	my $check = Test::FakeCheck->new(
		iaas => 'pve',
		raw  => $wrap->($raw),
		data => $wrap->($evaluated // $raw),
	);
	my $ok = $check->check_environment_parameters();
	my $msg = join("\n", map { $_->{msg} } grep { $_->{status} eq 'failed' } $check->results);
	return ($ok, $msg =~ s/#\w\{([^}]*)\}/$1/gr =~ s/\s+/ /gr);
}

sub entry {
	my ($properties, %extra) = @_;
	return { name => 'pve-az1', type => 'pve', properties => $properties, %extra };
}

for my $case (
	['properties.pve.api_token', [entry({ pve => { %HOST, api_token => 'SYNTHETIC-TOKEN' } })]],
	['properties.pve.password',  [entry({ pve => { %HOST, password => 'SYNTHETIC-PASSWORD' } })]],
	['properties.pve_api_token', [entry({ pve => { %HOST }, pve_api_token => 'SYNTHETIC-TOKEN' })]],
	['properties.pve_password',  [entry({ pve => { %HOST }, pve_password => 'SYNTHETIC-PASSWORD' })]],
	['properties.pve.api_token', [entry({ pve => { %HOST, api_token => '(( grab params.pve_api_token ))' } })],
		[entry({ pve => { %HOST, api_token => 'SYNTHETIC-TOKEN' } })]],
	['properties.pve.api_token', [entry({ pve => { %HOST, api_token => '(( vault "secret/x:api_token" || "SYNTHETIC-TOKEN" ))' } })]],
	['properties.pve.api_token', [entry({ pve => { %HOST, api_token => '(( concat "kit-test@pve!" "SYNTHETIC" ))' } })]],
	['properties.pve.api_token', [entry({ pve => { %HOST, api_token => '(( vault params.token_path ))' } })]],
	['properties.pve.api_token', [entry({ pve => { %HOST, api_token => '((pve-api-token))' } })]],
	['properties.pve.password',  [entry({ pve => { %HOST, password => { value => 'SYNTHETIC-PASSWORD' } } })]],
	['properties.pve.password',  [entry({ pve => { %HOST, api_token => $VAULT_TOKEN, password => undef } })]],
	['properties',               [entry('(( grab params.pve_props ))')],
		[entry({ pve => { %HOST, api_token => 'SYNTHETIC-TOKEN' } })]],
	['properties.pve',           [entry({ pve => '(( grab params.pve_props ))' })],
		[entry({ pve => { %HOST, api_token => 'SYNTHETIC-TOKEN' } })]],
	['bosh-configs.director-cpi.cpis', '(( grab params.inline_cpis ))',
		[entry({ pve => { %HOST, api_token => 'SYNTHETIC-TOKEN' } })]],
	['type', [entry({ pve => { %HOST }, pve_api_token => 'SYNTHETIC-TOKEN' }, type => '(( grab params.inline_cpi_type ))')],
		[entry({ pve => { %HOST }, pve_api_token => 'SYNTHETIC-TOKEN' })]],
	['type', [entry({ pve => { %HOST, api_token => $VAULT_TOKEN } }, type => '(( grab params.inline_cpi_type ))')],
		[entry({ pve => { %HOST, api_token => 'SYNTHETIC-TOKEN' } })]],
) {
	my ($path, $raw, $evaluated) = @$case;
	my ($ok, $msg) = inline_check($raw, $evaluated);
	ok(!$ok, "an inline pve entry with a bad $path fails the check");
	like($msg, qr/(?<![\w.])\Q$path\E(?![\w.])/, "and the message names $path");
	like($msg, qr/pve-az1|director-cpi\.cpis/, "and the message names the entry for $path");
	unlike($msg, qr/SYNTHETIC-(?:TOKEN|PASSWORD)/, "and does not print a credential for $path");
}

{
	my ($ok, $msg) = inline_check([
		entry({ pve => { %HOST, api_token => $VAULT_TOKEN } }),
		entry({ pve => { %HOST }, pve_password => 'SYNTHETIC-PASSWORD' }, name => 'pve-az2'),
	]);
	ok(!$ok, 'a literal in the second inline entry fails the check');
	like($msg, qr/cpis\[1\]/, 'and the message names the second entry by index');
	like($msg, qr/pve-az2/, 'and by name');
}

for my $case (
	['a nested (( vault ))',         { pve => { %HOST, api_token => $VAULT_TOKEN } }],
	['a flat (( vault ))',           { pve => { %HOST }, pve_api_token => $VAULT_TOKEN }],
	['a split (( vault ))',          { pve => { %HOST, password => '(( vault "secret/x" ":password" ))' } }],
	['a nested absolute reference',  { pve => { %HOST, api_token => $ABS_TOKEN } }],
	['a flat absolute reference',    { pve => { %HOST }, pve_api_token => $ABS_TOKEN }],
	['a storage set named secret',   { pve => { %HOST, api_token => $VAULT_TOKEN }, pve_storage_sets => { secret => { %SET } } }],
	['a nested storage set named password', { pve => { %HOST, api_token => $VAULT_TOKEN, storage_sets => { password => { %SET } } } }],
) {
	my ($what, $properties) = @$case;
	# The evaluated view holds the literal token, as Genesis's lookup would.
	my $evaluated = entry({ pve => { %HOST, api_token => 'SYNTHETIC-TOKEN' }, pve_api_token => 'SYNTHETIC-TOKEN' });
	my ($ok, $msg) = inline_check([entry($properties)], [$evaluated]);
	ok($ok, "an inline pve entry with $what passes");
	is($msg, '', "with nothing reported for $what");
}

{
	my ($ok, $msg) = inline_check([
		{ name => 'vsphere-dc1', type => 'vsphere', properties => { password => 'SYNTHETIC-PASSWORD' } },
	]);
	ok($ok, 'a non-PVE inline entry with a literal password is left alone');
}

{
	my ($ok, $msg) = inline_check([{ name => 'pve-az1', properties => { pve => { %HOST } } }]);
	ok(!$ok, 'an inline entry without a type fails the check');
	like($msg, qr/type/, 'and the message names the type');
}

done_testing;
