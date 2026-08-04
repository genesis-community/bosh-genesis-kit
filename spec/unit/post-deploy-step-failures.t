#!/usr/bin/env perl
# Unit tests for post-deploy step failure propagation in hooks/post-deploy.pm.
#
# perform() runs five post-deployment steps against the director that was
# just deployed. It used to call each one for effect and then `return
# $self->done(1)` unconditionally, so every step's result was discarded.
#
# Genesis bails when a module hook's perform() returns false
# (Genesis::Kit::run_hook), which is the only channel a kit hook has for
# failing the run -- so discarding the results made every post-deploy
# failure exit zero. Observed 2026-08-03: `upload_stemcells` failed with
# "Failed to find variable '/cpi-config/properties/pve-api-token-az1' from
# config server: HTTP Code '404'", genesis printed the error and exited 0,
# and the director sat there with no stemcell until a CF deploy failed
# against it hours later with an unrelated-looking message.
#
# The steps follow the Genesis convention of 1 for success, 0 for failure,
# and a bare `return` (undef) for "nothing to do". The undef case is load
# bearing: upload_stemcells returns it when an operator answers "no" to the
# interactive upload prompt, which is a choice, not a failure.
#
# Required cases:
#   (a) all steps succeed -> perform() is truthy, genesis exits zero.
#   (b) any step returning 0 -> perform() is FALSE, so genesis bails.
#   (c) a step returning undef (skipped/declined) is not a failure.
#   (d) the error names every failed step and how to retry it, because the
#       generic bail genesis prints afterwards names none of them.
#   (e) a failed deployment still returns truthy: the deploy already failed
#       through its own path and must not be reported twice.
use strict;
use warnings;
use FindBin;
use Test::More;

my $hook_file = "$FindBin::Bin/../../hooks/post-deploy.pm";
require $hook_file;

# --- Test doubles ------------------------------------------------------

package Test::FakeEnv;

sub new { return bless {}, shift }

sub use_create_env          { return 0 }
sub get_call_path_with_env  { return 'genesis test-env' }
sub has_feature             { return 0 }
sub name                    { return 'test-env' }

package Test::PostDeployHook;

our @ISA = ('Genesis::Hook::PostDeploy::BOSH');

# new blesses the object directly rather than going through init(), which
# demands a real Genesis::Env. Everything perform() touches is either
# overridden below or served by Test::FakeEnv.
sub new {
	my ($class, %opts) = @_;

	return bless {
		env      => Test::FakeEnv->new,
		rc       => $opts{rc} // 0,
		outcomes => $opts{outcomes} // {},
		called   => [],
	}, $class;
}

sub _step {
	my ($self, $name) = @_;

	push @{$self->{called}}, $name;

	return exists $self->{outcomes}{$name} ? $self->{outcomes}{$name} : 1;
}

sub upload_director_cpi_config     { return $_[0]->_step('cpi_config') }
sub update_director_network_config { return $_[0]->_step('network_config') }
sub _upload_dns_runtime_config     { return $_[0]->_step('dns_runtime_config') }
sub upload_runtime_config_releases { return $_[0]->_step('runtime_releases') }
sub upload_stemcells               { return $_[0]->_step('stemcells') }

package Test::FakeBosh;

sub new { my ($class, %o) = @_; return bless {rc => $o{rc} // 0}, $class }

sub execute { return (undef, $_[0]->{rc}) }

package Test::FakeKit;

sub new { return bless {}, shift }

sub path { return "$FindBin::Bin/../../$_[1]" }

package Test::ReleaseUploadEnv;

our @ISA = ('Test::FakeEnv');

sub new {
	my ($class, %o) = @_;

	return bless {bosh => Test::FakeBosh->new(rc => $o{rc} // 0)}, $class;
}

sub lookup          { return $_[2] }
sub kit             { return Test::FakeKit->new }
sub get_target_bosh { return $_[0]->{bosh} }
sub notify          { return 1 }

package Test::ReleaseUploadHook;

our @ISA = ('Genesis::Hook::PostDeploy::BOSH');

# Stubs every step except upload_runtime_config_releases, which runs for
# real against a fake bosh so its own result convention is under test.
sub new {
	my ($class, %opts) = @_;

	return bless {
		env => Test::ReleaseUploadEnv->new(rc => $opts{rc} // 0),
		rc  => 0,
	}, $class;
}

sub upload_director_cpi_config     { return 1 }
sub update_director_network_config { return 1 }
sub _upload_dns_runtime_config     { return 1 }
sub upload_stemcells               { return 1 }

package main;

# run_perform drives perform() with STDOUT/STDERR captured, so Genesis'
# info/error output does not land in the middle of the TAP stream.
sub run_perform {
	my ($hook) = @_;

	my $captured = '';

	open(my $save_out, '>&', \*STDOUT) or die "cannot dup STDOUT: $!";
	open(my $save_err, '>&', \*STDERR) or die "cannot dup STDERR: $!";

	close(STDOUT);
	close(STDERR);
	open(STDOUT, '>',  \$captured) or die "cannot capture STDOUT: $!";
	open(STDERR, '>>', \$captured) or die "cannot capture STDERR: $!";

	my $result = eval { $hook->perform() };
	my $err = $@;

	close(STDOUT);
	close(STDERR);
	open(STDOUT, '>&', $save_out) or die "cannot restore STDOUT: $!";
	open(STDERR, '>&', $save_err) or die "cannot restore STDERR: $!";

	die $err if $err;

	return ($result, $captured);
}

subtest 'every step succeeding leaves the hook successful' => sub {
	my $hook = Test::PostDeployHook->new;
	my ($result) = run_perform($hook);

	ok($result, 'perform() reports success when no step failed');
	is_deeply(
		$hook->{called},
		[qw/cpi_config network_config dns_runtime_config runtime_releases stemcells/],
		'all five post-deploy steps ran, in order'
	);
};

subtest 'a failed stemcell upload fails the hook' => sub {
	my $hook = Test::PostDeployHook->new(outcomes => {stemcells => 0});
	my ($result, $out) = run_perform($hook);

	ok(!$result, 'perform() reports failure so genesis bails instead of exiting zero');
	like($out, qr/stemcell/i, 'the failure names the step');
	like($out, qr/upload-stemcells/, 'the failure names the command that retries it');
};

subtest 'a declined or skipped step is not a failure' => sub {
	# upload_stemcells returns undef when an operator answers "no" to the
	# interactive prompt, and when there is nothing to do.
	my $hook = Test::PostDeployHook->new(outcomes => {stemcells => undef});
	my ($result) = run_perform($hook);

	ok($result, 'an undefined result is "nothing to do", not a failure');
};

subtest 'every failed step is named with its retry command' => sub {
	my $hook = Test::PostDeployHook->new(
		outcomes => {cpi_config => 0, dns_runtime_config => 0, stemcells => 0}
	);
	my ($result, $out) = run_perform($hook);

	ok(!$result, 'perform() reports failure');
	like($out, qr/cpi-config/,        'the cpi-config step is named');
	like($out, qr/rc dns/,            'the dns runtime-config retry is named');
	like($out, qr/upload-stemcells/,  'the stemcell retry is named');
	like($out, qr/deployment(?:\s+\w+)*\s+succeeded/i,
		'the operator is told the deployment itself succeeded');
};

subtest 'each step is checked independently' => sub {
	for my $step (qw/cpi_config network_config dns_runtime_config runtime_releases stemcells/) {
		my $hook = Test::PostDeployHook->new(outcomes => {$step => 0});
		my ($result) = run_perform($hook);

		ok(!$result, "a failed $step step fails the hook");
	}
};

subtest 'a failed release upload is reported as a step failure' => sub {
	# upload_runtime_config_releases used to `return 1` whatever bosh said,
	# so the step could be listed as checked and still never fail. Without
	# the bosh-dns release on the director, the first workload deployed
	# against it dies at task creation with "Release 'bosh-dns' doesn't
	# exist" -- exactly the kind of late, unrelated-looking failure the
	# result plumbing exists to prevent.
	my $hook = Test::ReleaseUploadHook->new(rc => 1);
	my ($result) = run_perform($hook);

	ok(defined($result) && !$result, 'a non-zero upload-release rc fails the step');

	my $ok_hook = Test::ReleaseUploadHook->new(rc => 0);
	my ($ok_result) = run_perform($ok_hook);

	ok($ok_result, 'a clean upload-release leaves the step successful');
};

subtest 'a failed deployment is not reported twice' => sub {
	my $hook = Test::PostDeployHook->new(rc => 1);
	my ($result) = run_perform($hook);

	ok($result, 'perform() stays successful when the deploy itself failed');
	is_deeply($hook->{called}, [], 'no post-deploy step runs against a failed deploy');
};

done_testing;
