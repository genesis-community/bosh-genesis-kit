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
use strict;
use warnings;
use FindBin;
use Test::More;

my $hook_file = "$FindBin::Bin/../../hooks/check.pm";
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
		env     => Test::FakeEnv->new(%{ $opts{data} // {} }),
		iaas    => $opts{iaas},
		is_ocfp => $opts{is_ocfp} // 0,
		results => [],
	}, $class;
}

sub env     { $_[0]{env} }
sub iaas    { $_[0]{iaas} }
sub is_ocfp { $_[0]{is_ocfp} }

sub start_check { return 1 }

# Genesis::Hook::Check::check_result returns truthy on success and falsey
# on failure; record what was reported so the tests can assert on the
# message the operator actually sees.
sub check_result {
	my ($self, $check, $status, $msg) = @_;
	$status //= 'ok';
	push @{ $self->{results} }, { check => $check, status => $status, msg => $msg // '' };
	return $status eq 'ok' ? 1 : 0;
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

done_testing;
