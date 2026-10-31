#!/usr/bin/env perl
# Unit tests for the inline director-cpi credential scan in
# hooks/post-deploy.pm.
#
# bosh-configs.director-cpi.cpis is uploaded to the director as it resolves,
# without passing through the cpi-config hook.  An (( vault )) value there
# is entombed into the director's own CredHub and arrives as an absolute
# ((/...)) reference, but a literal, or any other Spruce expression such as
# (( grab params.pve_api_token )), resolves to the credential itself and
# would be stored in the director's cpi config in plaintext.
#
# The kit's upload_director_cpi_config reads the block the way Genesis does,
# through lookup_entombed_self, and refuses the upload when a PVE entry
# holds a credential that is not an absolute reference.  The rule is the one
# the cpi-config hook applies to its own output, and the shared case table
# in fixtures/pve-credential-cases.pl drives both.
#
# Required cases:
#   (a) a disabled CPI forwards to Genesis before any lookup.
#   (b) every refused case in the table returns 0, names the entry and the
#       key, and uploads nothing.
#   (c) every accepted case forwards to the upload.
#   (d) a resolved type of pve is judged, whatever the raw type was.
#   (e) an entry of another type is left alone.
#   (f) without an inline block the upload runs as before.
use strict;
use warnings;
use FindBin;
use Test::More;

my $kit_dir = "$FindBin::Bin/../..";
require "$kit_dir/hooks/post-deploy.pm";

my $CASES = do "$FindBin::Bin/fixtures/pve-credential-cases.pl"
	or die "cannot load the case table: $@$!";

# --- Test doubles ------------------------------------------------------

package Test::FakeKit;

sub new  { my ($class, $dir) = @_; return bless { dir => $dir }, $class }
sub path { my ($self, $file) = @_; return "$self->{dir}/$file" }

package Test::FakeEnv;

# lookup_entombed_self serves a prepared payload, as Genesis would after
# entombing the env's vault values into the director's own CredHub.  With
# cpi_enabled false it dies if called, because Genesis makes no lookup then.
sub new {
	my ($class, %opts) = @_;
	return bless {
		cpi_enabled => $opts{cpi_enabled} // 1,
		cpis        => $opts{cpis},
		kit         => Test::FakeKit->new($kit_dir),
		lookups     => [],
		uploads     => 0,
	}, $class;
}

sub kit         { $_[0]{kit} }
sub cpi_enabled { $_[0]{cpi_enabled} }

sub lookup_entombed_self {
	my ($self, $key, $default) = @_;
	die "lookup_entombed_self called with the CPI disabled\n" unless $self->{cpi_enabled};
	push @{$self->{lookups}}, $key;
	return $default unless $key eq 'bosh-configs.director-cpi.cpis' && defined $self->{cpis};
	return $self->{cpis};
}

sub upload_director_cpi_config {
	my ($self) = @_;
	$self->{uploads}++;
	return 1;
}

package Test::PostDeployHook;

our @ISA = ('Genesis::Hook::PostDeploy::BOSH');

# new blesses the object directly rather than going through init(), which
# demands a real Genesis::Env.
sub new {
	my ($class, %opts) = @_;
	return bless { env => Test::FakeEnv->new(%opts) }, $class;
}

sub env { $_[0]{env} }

package main;

# Runs the step and returns its result and whatever it reported through
# Genesis's error(), with colour codes and line wrapping removed.
sub run_step {
	my (%opts) = @_;
	my $hook = Test::PostDeployHook->new(%opts);
	my @errors;
	my $result = do {
		no warnings 'redefine';
		local *Genesis::Hook::PostDeploy::BOSH::error = sub {
			my ($fmt, @args) = @_;
			push @errors, @args ? sprintf($fmt, @args) : $fmt;
		};
		$hook->upload_director_cpi_config();
	};
	my $errors = join("\n", @errors) =~ s/\e\[[0-9;]*m//gr =~ s/#\w\{([^}]*)\}/$1/gr =~ s/\s+/ /gr;
	return ($result, $errors, $hook->env);
}

sub pve_entry {
	my ($properties, %extra) = @_;
	return { name => 'pve-az1', type => 'pve', properties => $properties, %extra };
}

# (a) A disabled CPI skips everything, as Genesis does.
{
	my ($result, $errors, $env) = run_step(
		cpi_enabled => 0,
		cpis        => [pve_entry({ pve_api_token => 'SYNTHETIC-TOKEN' })],
	);
	ok($result, 'a disabled CPI does not fail the step');
	is($env->{uploads}, 1, 'and forwards to the Genesis upload');
	is_deeply($env->{lookups}, [], 'without looking anything up');
}

# (b) Every refused case in the shared table stops the upload.
for my $case (@{$CASES->{refused}}) {
	my ($path, $properties) = @$case;
	my ($result, $errors, $env) = run_step(cpis => [pve_entry($properties)]);
	is($result, 0, "a resolved $path that is not a reference fails the step");
	is($env->{uploads}, 0, "and nothing is uploaded for $path");
	like($errors, qr/pve-az1/, "and the error names the entry for $path");
	like($errors, qr/(?<![\w.])properties\.\Q$path\E(?![\w.])/, "and the error names properties.$path");
	unlike($errors, qr/SYNTHETIC-(?:TOKEN|PASSWORD)/, "and the error does not print the value for $path");
}

{
	my ($result, $errors, $env) = run_step(
		cpis => [pve_entry({ pve_api_token => '((pve-api-token))' })],
	);
	is($result, 0, 'a relative reference fails the step, because a cpi config needs absolute names');
	is($env->{uploads}, 0, 'and nothing is uploaded');
}

# The second entry is the bad one, so the error has to say which.
{
	my ($result, $errors, $env) = run_step(cpis => [
		pve_entry({ pve_api_token => '((/cpi-config/properties/pve-api-token-az1))' }),
		pve_entry({ pve_api_token => 'SYNTHETIC-TOKEN' }, name => 'pve-az2'),
	]);
	is($result, 0, 'a literal in the second entry fails the step');
	like($errors, qr/pve-az2/, 'and the error names the second entry');
	is($env->{uploads}, 0, 'and nothing is uploaded');
}

# (c) Every accepted case reaches the upload.
for my $case (@{$CASES->{accepted}}) {
	my ($what, $properties) = @$case;
	my ($result, $errors, $env) = run_step(cpis => [pve_entry($properties)]);
	ok($result, "$what passes");
	is($env->{uploads}, 1, "and $what is uploaded");
	is($errors, '', "with nothing reported for $what");
}

# (d) The raw env wrote type: (( grab params.inline_cpi_type )), which hides
#     the entry from the check hook.  The resolved type is what counts here.
{
	my ($result, $errors, $env) = run_step(cpis => [{
		name       => 'pve-az1',
		type       => 'pve',
		properties => { pve => { host => '10.0.0.1' }, pve_api_token => 'SYNTHETIC-TOKEN' },
	}]);
	is($result, 0, 'an entry that resolves to type pve is judged');
	is($env->{uploads}, 0, 'and nothing is uploaded');
}

# (e) The rule is the PVE CPI's, so another CPI's properties are not judged.
{
	my ($result, $errors, $env) = run_step(cpis => [
		{ name => 'vsphere-dc1', type => 'vsphere', properties => { password => 'SYNTHETIC-PASSWORD' } },
	]);
	ok($result, 'a non-PVE entry with a literal password is left alone');
	is($env->{uploads}, 1, 'and is uploaded');
}

# (f) No inline block leaves the upload to the cpi-config hook.
{
	my ($result, $errors, $env) = run_step();
	ok($result, 'without an inline block the step passes');
	is($env->{uploads}, 1, 'and the upload runs the cpi-config hook as before');
}

done_testing;
