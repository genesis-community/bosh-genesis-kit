#!/usr/bin/env perl
# Unit tests for the stemcell-selection helpers in hooks/post-deploy.pm:
# _select_stemcell and _resolve_stemcell_os.
#
# Like build_az_definitions (see cloud-config-director-az-map.t), these run
# only inside the post-deploy hook against a live director, so spec/spec.t's
# genesis-manifest pipeline never reaches them.  This file loads the real
# hook module and drives both helpers directly; _resolve_stemcell_os gets a
# thin env double providing lookup/manifest_lookup.
#
# Contracts under test:
#   _select_stemcell(version, available):
#     - available is pre-sorted newest-first by the caller, so undef or
#       'latest' selects the head of the list;
#     - an exact version pin selects the matching entry only;
#     - a pin with no match returns undef (caller decides how to fail);
#     - empty or undef available returns undef.
#   _resolve_stemcell_os(env) precedence:
#     params.stemcell_os > deployed manifest's first stemcell os > the
#     kit default (DEFAULT_STEMCELL_OS) -- the manifest middle step is
#     what fixes the jammy-on-noble bug without every env setting
#     params.stemcell_os.
use strict;
use warnings;
use FindBin;
use Test::More;

my $hook_file = "$FindBin::Bin/../../hooks/post-deploy.pm";
require $hook_file;

# --- Test double -------------------------------------------------------

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

sub manifest_lookup {
	my ($self, $key, $default) = @_;
	return exists $self->{data}{manifest}{$key}
		? $self->{data}{manifest}{$key}
		: $default;
}

package main;

my $class = 'Genesis::Hook::PostDeploy::BOSH';
my $hook  = bless {}, $class;

my @available = (
	{ version => '1.926', os => 'ubuntu-noble' },
	{ version => '1.918', os => 'ubuntu-noble' },
	{ version => '1.903', os => 'ubuntu-noble' },
);

subtest '_select_stemcell picks newest for undef or latest' => sub {
	my $sel = Genesis::Hook::PostDeploy::BOSH::_select_stemcell(undef, \@available);
	is($sel->{version}, '1.926', 'undef version selects head of list');

	$sel = Genesis::Hook::PostDeploy::BOSH::_select_stemcell('latest', \@available);
	is($sel->{version}, '1.926', "'latest' selects head of list");
};

subtest '_select_stemcell honors an exact version pin' => sub {
	my $sel = Genesis::Hook::PostDeploy::BOSH::_select_stemcell('1.918', \@available);
	is($sel->{version}, '1.918', 'pin selects the exact matching entry');
	is($sel->{os}, 'ubuntu-noble', 'the full entry comes back, not just the version');
};

subtest '_select_stemcell returns undef on a pin miss' => sub {
	my $sel = Genesis::Hook::PostDeploy::BOSH::_select_stemcell('1.999', \@available);
	is($sel, undef, 'unmatched pin returns undef rather than falling back to latest');
};

subtest '_select_stemcell returns undef with nothing available' => sub {
	is(Genesis::Hook::PostDeploy::BOSH::_select_stemcell('1.918', []), undef,
		'empty list returns undef');
	is(Genesis::Hook::PostDeploy::BOSH::_select_stemcell('1.918', undef), undef,
		'undef list returns undef');
	is(Genesis::Hook::PostDeploy::BOSH::_select_stemcell(undef, []), undef,
		'empty list returns undef even without a pin');
};

subtest '_select_stemcell skips entries without a version' => sub {
	my $sel = Genesis::Hook::PostDeploy::BOSH::_select_stemcell(
		'1.918', [ { os => 'ubuntu-noble' }, { version => '1.918' } ]);
	is($sel->{version}, '1.918', 'version-less entries cannot match a pin');
};

subtest '_resolve_stemcell_os prefers explicit params.stemcell_os' => sub {
	my $env = Test::FakeEnv->new(
		params   => { stemcell_os => 'ubuntu-noble' },
		manifest => { stemcells => [ { os => 'ubuntu-jammy' } ] },
	);
	is($hook->_resolve_stemcell_os($env), 'ubuntu-noble',
		'params.stemcell_os wins over the deployed manifest');
};

subtest '_resolve_stemcell_os falls back to the deployed manifest os' => sub {
	my $env = Test::FakeEnv->new(
		manifest => { stemcells => [ { os => 'ubuntu-noble' }, { os => 'ubuntu-jammy' } ] },
	);
	is($hook->_resolve_stemcell_os($env), 'ubuntu-noble',
		'first manifest stemcell os is used when params.stemcell_os is unset');
};

subtest '_resolve_stemcell_os defaults when nothing else is known' => sub {
	my $env = Test::FakeEnv->new;
	is($hook->_resolve_stemcell_os($env),
		Genesis::Hook::PostDeploy::BOSH::DEFAULT_STEMCELL_OS(),
		'no params, no manifest: kit default');

	$env = Test::FakeEnv->new(manifest => { stemcells => [ {} ] });
	is($hook->_resolve_stemcell_os($env),
		Genesis::Hook::PostDeploy::BOSH::DEFAULT_STEMCELL_OS(),
		'manifest stemcell without an os still falls through to the default');
};

done_testing;
