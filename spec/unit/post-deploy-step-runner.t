#!/usr/bin/env perl
# Unit tests for the post-deploy step runner in hooks/post-deploy.pm.
#
# The post-deploy steps are not independent: the bosh-dns runtime config
# must not be uploaded when the release it references failed to upload,
# or the director is left in a state where every subsequent workload
# deploy fails at task creation with "Release 'bosh-dns' doesn't exist".
# The runner therefore executes a list of step hashrefs whose `needs`
# edges carry a policy for what a prerequisite failure means:
#
#   skip  - do not run; report the step as blocked, with its retry command
#   run   - run anyway; record a note that a prerequisite had failed
#   abort - stop the whole post-deploy; report everything not run
#
# Conventions preserved from the flat-list version: a step method returns
# 1 for success, defined-false for failure, and undef for "nothing to do"
# (noop).  A noop never blocks dependents -- "operator declined the
# stemcell prompt" is not a failure.  Skips propagate transitively: a
# step whose prerequisite was itself skipped is also blocked.
#
# spec/spec.t cannot cover any of this: the golden-manifest comparison
# never runs post-deploy hooks.  This file loads the real hook module and
# drives _run_post_deploy_steps with scripted step methods; the runner
# under test is unmodified kit code.
use strict;
use warnings;
use FindBin;
use Test::More;

my $hook_file = "$FindBin::Bin/../../hooks/post-deploy.pm";
require $hook_file;

# --- Test double -------------------------------------------------------

package Test::FakeHook;

# Inherit the real hook module under test -- _run_post_deploy_steps and
# _validate_post_deploy_steps are NOT overridden, so the kit's own code
# runs.  Only the step methods themselves are scripted.
our @ISA = ('Genesis::Hook::PostDeploy::BOSH');

sub new {
	my ($class, %opts) = @_;
	return bless {
		returns => $opts{returns} // {},
		calls   => [],
	}, $class;
}

sub calls { @{ $_[0]{calls} } }

# Scripted step methods: each records its invocation and returns exactly
# what the test scripted for it (including an explicit undef for noop).
for my $m (qw/step_a step_b step_c step_d/) {
	no strict 'refs';
	*{"Test::FakeHook::$m"} = sub {
		my ($self) = @_;
		push @{ $self->{calls} }, $m;
		return $self->{returns}{$m};
	};
}

package main;

sub steps {
	# Convenience: build step hashrefs with defaults, so tests only spell
	# out what they are about.
	map {
		my %s = %$_;
		$s{label} //= "label-$s{id}";
		$s{retry} //= "%s retry-$s{id}";
		\%s;
	} @_;
}

# (1) every step succeeds: all run in declared order, nothing reported.
{
	my $hook = Test::FakeHook->new(returns => {step_a => 1, step_b => 1});
	my $report = $hook->_run_post_deploy_steps(steps(
		{id => 'a', method => 'step_a'},
		{id => 'b', method => 'step_b', needs => {a => 'skip'}},
	));
	is_deeply([$hook->calls], ['step_a', 'step_b'], 'both steps run in order');
	is_deeply($report->{failed},  [], 'no failures reported');
	is_deeply($report->{skipped}, [], 'no skips reported');
	ok(!$report->{aborted}, 'not aborted');
}

# (2) skip policy: a failed prerequisite blocks the dependent, which is
#     reported with the step it was blocked by and its retry command.
{
	my $hook = Test::FakeHook->new(returns => {step_a => 0, step_c => 1});
	my $report = $hook->_run_post_deploy_steps(steps(
		{id => 'a', method => 'step_a'},
		{id => 'b', method => 'step_b', needs => {a => 'skip'}},
		{id => 'c', method => 'step_c'},
	));
	is_deeply([$hook->calls], ['step_a', 'step_c'],
		'blocked step does not run; unrelated later step still does');
	is_deeply([map {$_->{id}} @{$report->{failed}}], ['a'], 'a is the failure');
	is_deeply([map {$_->{id}} @{$report->{skipped}}], ['b'], 'b is skipped');
	is($report->{skipped}[0]{because}, 'a', 'skip names the blocking step');
	is($report->{skipped}[0]{retry}, '%s retry-b',
		'skipped step keeps its retry command for the operator');
}

# (3) skips propagate: a step whose prerequisite was skipped is blocked
#     for the same root cause.
{
	my $hook = Test::FakeHook->new(returns => {step_a => 0});
	my $report = $hook->_run_post_deploy_steps(steps(
		{id => 'a', method => 'step_a'},
		{id => 'b', method => 'step_b', needs => {a => 'skip'}},
		{id => 'c', method => 'step_c', needs => {b => 'skip'}},
	));
	is_deeply([$hook->calls], ['step_a'], 'only the root step runs');
	is_deeply([sort map {$_->{id}} @{$report->{skipped}}], ['b', 'c'],
		'both dependents are skipped');
}

# (4) noop (undef) is not failure and never blocks.
{
	my $hook = Test::FakeHook->new(returns => {step_a => undef, step_b => 1});
	my $report = $hook->_run_post_deploy_steps(steps(
		{id => 'a', method => 'step_a'},
		{id => 'b', method => 'step_b', needs => {a => 'skip'}},
	));
	is_deeply([$hook->calls], ['step_a', 'step_b'], 'noop does not block');
	is_deeply($report->{failed},  [], 'noop is not a failure');
	is_deeply($report->{skipped}, [], 'nothing skipped');
}

# (5) run policy: soft dependency runs anyway, with a note for the report.
{
	my $hook = Test::FakeHook->new(returns => {step_a => 0, step_b => 1});
	my $report = $hook->_run_post_deploy_steps(steps(
		{id => 'a', method => 'step_a'},
		{id => 'b', method => 'step_b', needs => {a => 'run'}},
	));
	is_deeply([$hook->calls], ['step_a', 'step_b'],
		'soft-dependent step runs despite the failure');
	is_deeply([map {$_->{id}} @{$report->{notes}}], ['b'],
		'a note records the degraded precondition');
	is($report->{notes}[0]{because}, 'a', 'note names the failed prerequisite');
}

# (6) abort policy: stop the whole post-deploy; the aborting step and
#     everything after it are reported as not run.
{
	my $hook = Test::FakeHook->new(returns => {step_a => 0});
	my $report = $hook->_run_post_deploy_steps(steps(
		{id => 'a', method => 'step_a'},
		{id => 'b', method => 'step_b', needs => {a => 'abort'}},
		{id => 'c', method => 'step_c'},
		{id => 'd', method => 'step_d'},
	));
	is_deeply([$hook->calls], ['step_a'], 'nothing runs after the abort fires');
	ok($report->{aborted}, 'report is marked aborted');
	is_deeply([map {$_->{id}} @{$report->{skipped}}], ['b', 'c', 'd'],
		'the aborting step and every remaining step are reported unrun');
	is_deeply([map {$_->{id}} @{$report->{failed}}], ['a'],
		'the root failure is still reported');
}

# (7) malformed step lists are developer errors and die at once.
{
	my $hook = Test::FakeHook->new;
	local $@;
	eval { $hook->_run_post_deploy_steps(steps(
		{id => 'a', method => 'step_a', needs => {b => 'skip'}},
		{id => 'b', method => 'step_b'},
	)); 1 };
	like($@, qr/\bearlier\b/i, 'needs must reference an earlier step');

	eval { $hook->_run_post_deploy_steps(steps(
		{id => 'a', method => 'step_a'},
		{id => 'b', method => 'step_b', needs => {a => 'maybe'}},
	)); 1 };
	like($@, qr/\bpolicy\b/i, 'unknown edge policy is rejected');

	eval { $hook->_run_post_deploy_steps(steps(
		{id => 'a', method => 'step_a'},
		{id => 'a', method => 'step_b'},
	)); 1 };
	like($@, qr/\bduplicate\b/i, 'duplicate step ids are rejected');
}

# (8) the kit's real step list is valid and encodes the dns dependency:
#     the runtime-config releases upload precedes the dns runtime-config
#     upload, and the latter is blocked when the former fails, so the
#     director can never hold a dns config that references a release
#     that is not there.
{
	my @steps = Genesis::Hook::PostDeploy::BOSH->_post_deploy_steps;
	local $@;
	eval { Genesis::Hook::PostDeploy::BOSH->_validate_post_deploy_steps(@steps); 1 };
	is($@, '', 'the kit step list passes validation');

	my %index = map {($steps[$_]{id} => $_)} 0..$#steps;
	ok(defined $index{'rc-releases'} && defined $index{'dns-rc'},
		'both dns-related steps are present');
	ok($index{'rc-releases'} < $index{'dns-rc'},
		'releases upload precedes the dns runtime-config upload');
	is(($steps[$index{'dns-rc'}]{needs} // {})->{'rc-releases'}, 'skip',
		'dns runtime-config is blocked when its release upload fails');

	my ($cc) = grep {$_->{id} eq 'cloud-config'} @steps;
	like($cc->{label}, qr/network/i,
		'cloud-config label mentions the network space it also defines');
}

done_testing;
