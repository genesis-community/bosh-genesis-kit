#!/usr/bin/env perl
# Unit tests for the OpenBao static seal support.
#
# spec/spec.t renders manifests for each seal mode, but most of the static
# seal work happens where no manifest shows it: the seal mode decision in
# hooks/features.pm, the key checks in hooks/check.pm, the curl calls that
# must keep tokens and keys off command lines, the static init path, the
# unseal flow that must never send keys blindly, and the post-deploy seal
# type comparison.  This file loads the real hook modules and drives those
# paths against thin doubles.  Every seal key here is fake: runs of 0a, 0b,
# and 0c bytes.
#
# Required cases:
#   (a) kit.yml scopes a fixed 64-character a-f0-9 key to
#       +openbao-static-seal, and nothing else generates it.
#   (b) the seal mode decision: param, exodus record, existing env, new env,
#       invalid values, and never dying.
#   (c) key validation catches surrounding whitespace (OpenBao 2.7 does not
#       trim the key file) without quoting the value.
#   (d) the derived key id matches the release's test vector.
#   (e) the check hook passes, warns, or fails each case without printing a
#       key, and checks the previous key's id during a rotation.
#   (f) openbao_request sends tokens and secret bodies on stdin only.
#   (g) static init backs up the recovery keys through stdin, prints them
#       exactly once, and mounts secret/ as KV v2.
#   (h) unseal refuses a pending migration and a non-interactive static
#       unseal without sending keys, and sends recovery keys one at a time
#       on stdin once a manual seal is confirmed.
#   (i) the post-deploy seal type check passes, fails, and skips correctly.
use strict;
use warnings;
use FindBin;
use Test::More;
use JSON::PP ();

my $root = "$FindBin::Bin/../..";
require "$root/hooks/features.pm";
require "$root/hooks/check.pm";
require "$root/hooks/post-deploy.pm";
require "$root/hooks/addon-openbao-init~oi.pm";
require "$root/hooks/addon-openbao-unseal~ou.pm";

my $H = 'Genesis::Hook::Features::BOSH';
my $KEY_A = '0a' x 32;
my $KEY_B = '0b' x 32;
my $KEY_C = '0c' x 32;

# --- Test doubles ------------------------------------------------------

package Test::FakeKit;
sub new  { return bless {}, shift }
sub path { return "$root/$_[1]" }

package Test::FakeVault;
# Secrets live in a hash of path => {key => value}.  Every query is
# recorded with its options and arguments so tests can prove what reached
# a command line and what went through stdin.
sub new { my ($class, %s) = @_; return bless {secrets => {%s}, queries => []}, $class }
sub has {
	my ($self, $path, $key) = @_;
	$path =~ s{^/+}{};
	return 0 unless exists $self->{secrets}{$path};
	return defined($key) ? exists($self->{secrets}{$path}{$key}) : 1;
}
sub get {
	my ($self, $path, $key) = @_;
	$path =~ s{^/+}{};
	my $data = $self->{secrets}{$path} or return defined($key) ? undef : {};
	return defined($key) ? $data->{$key} : {%$data};
}
sub query {
	my ($self, $opts, @args) = @_;
	push @{$self->{queries}}, {opts => {%$opts}, args => [@args]};
	if ($args[0] eq 'export') {
		my $path = $args[1];
		return ('', 1) unless exists $self->{secrets}{$path};
		return (JSON::PP->new->encode({$path => $self->{secrets}{$path}}), 0);
	}
	if ($args[0] eq 'import') {
		my $data = JSON::PP->new->decode($opts->{stdin});
		$self->{secrets}{$_} = $data->{$_} for keys %$data;
		return ('', 0);
	}
	return ('', 1);
}

package Test::FakeEnv;
sub new {
	my ($class, %o) = @_;
	return bless {
		params   => $o{params} // {},
		exodus   => $o{exodus} // {},
		exodus_dies => $o{exodus_dies},
		features => $o{features} // ['openbao'],
		vault    => $o{vault} // Test::FakeVault->new,
	}, $class;
}
sub lookup {
	my ($self, $key, $default) = @_;
	$key =~ s/^params\.// or return $default;
	return exists $self->{params}{$key} ? $self->{params}{$key} : $default;
}
sub exodus_lookup {
	my ($self, $key, $default) = @_;
	die "vault is sealed\n" if $self->{exodus_dies};
	return exists $self->{exodus}{$key} ? $self->{exodus}{$key} : $default;
}
sub has_feature  { my ($self, $f) = @_; return scalar grep {$_ eq $f} @{$self->{features}} }
sub features     { return @{$_[0]->{features}} }
sub vault        { return $_[0]->{vault} }
sub secrets_base { return 'secret/test/bosh/' }
sub kit          { return Test::FakeKit->new }
sub name         { return 'test' }
sub use_create_env         { return 1 }
sub get_call_path_with_env { return 'genesis test' }

package Test::CheckHook;
our @ISA = ('Genesis::Hook::Check::BOSH');
sub new          { my ($class, $env) = @_; return bless {env => $env}, $class }
sub want_feature { my ($self, $f) = @_; return $self->{env}->has_feature($f) }

package main;

# capture runs a block with STDOUT and STDERR captured, so Genesis output
# does not land in the TAP stream, and returns (result, output, error).
sub capture(&) {
	my ($code) = @_;
	my $out = '';
	open(my $save_out, '>&', \*STDOUT) or die "cannot dup STDOUT: $!";
	open(my $save_err, '>&', \*STDERR) or die "cannot dup STDERR: $!";
	close STDOUT; close STDERR;
	open(STDOUT, '>', \$out) or die "cannot capture STDOUT: $!";
	open(STDERR, '>>', \$out) or die "cannot capture STDERR: $!";
	my @result = eval { $code->() };
	my $err = $@;
	close STDOUT; close STDERR;
	open(STDOUT, '>&', $save_out) or die "cannot restore STDOUT: $!";
	open(STDERR, '>&', $save_err) or die "cannot restore STDERR: $!";
	return ($result[0], $out =~ s/\e\[[0-9;]*m//gr, $err);
}

# Fresh state per env: openbao_seal_state memoizes on the env object.
sub state_for { return $H->openbao_seal_state(Test::FakeEnv->new(@_)) }

# The seal-mode probe calls curl; these tests never reach a network, and an
# env without params.static_ip has no URL, so the probe reports nothing.

# --- (a) kit.yml credential --------------------------------------------

subtest 'kit.yml scopes a fixed hex seal key to +openbao-static-seal' => sub {
	require Genesis;
	require Genesis::Env::Secrets::Parser::FromKit;
	my $kit = Genesis::load_yaml_file("$root/kit.yml");
	my $parse = sub {
		Genesis::Env::Secrets::Parser::FromKit->new(undef)
			->parse(kit_metadata => $kit, features => [@_]);
	};
	my ($key) = grep {$_->path eq 'openbao/seal/static:key'}
		$parse->('vsphere', 'openbao', '+openbao-static-seal');
	ok($key, 'the static seal feature defines openbao/seal/static:key');
	is($key->get('size'), 64, '64 characters');
	is($key->get('valid_chars'), 'a-f0-9', 'lowercase hex only');
	ok($key->get('fixed'), 'fixed, so rotate-secrets never replaces it');
	ok(!(grep {$_->path =~ m{^openbao/seal/}} $parse->('vsphere', 'openbao')),
		'openbao without the static seal feature defines no seal secret');
	ok(!(grep {$_->path =~ m{^openbao/seal/}} $parse->('vsphere')),
		'an env without openbao defines no seal secret');
};

# --- (b) seal mode decision --------------------------------------------

subtest 'seal mode decision' => sub {
	my $s = state_for(params => {openbao_seal => 'static'});
	is_deeply([@$s{qw/mode valid source/}], ['static', 1, 'param'], 'param static');
	$s = state_for(params => {openbao_seal => 'shamir'}, exodus => {openbao_seal => 'static'});
	is_deeply([@$s{qw/mode valid source/}], ['shamir', 1, 'param'], 'the param wins over the exodus record');
	$s = state_for(params => {openbao_seal => 'auto'});
	is_deeply([@$s{qw/mode valid/}], ['shamir', 0], 'an invalid value renders shamir and is flagged');
	$s = state_for(params => {openbao_seal => ['static']});
	is_deeply([@$s{qw/mode valid/}], ['shamir', 0], 'a non-scalar value is flagged');
	$s = state_for(exodus => {has_openbao => 1, openbao_seal => 'static'});
	is_deeply([@$s{qw/mode source/}], ['static', 'exodus'], 'the recorded mode is kept without the param');
	$s = state_for(exodus => {has_openbao => 1});
	is_deeply([@$s{qw/mode existing source/}], ['shamir', 1, 'existing-default'],
		'an existing env without a record keeps shamir');
	$s = state_for(exodus_dies => 1);
	is_deeply([@$s{qw/mode existing/}], ['shamir', 1], 'an unreadable exodus counts as existing');
	$s = state_for();
	is_deeply([@$s{qw/mode existing source/}], ['static', 0, 'new-default'], 'a new env defaults to static');

	my $env = Test::FakeEnv->new;
	no warnings 'redefine';
	local *Test::FakeEnv::lookup = sub { die "boom\n" };
	my $d = $H->openbao_seal_state($env);
	is($d->{mode}, 'shamir', 'a failing lookup resolves to shamir instead of dying');
};

# --- (c) and (d) key validation and id derivation ----------------------

subtest 'static key validation never quotes the key' => sub {
	is($H->openbao_static_key_problem($KEY_A), undef, '64 lowercase hex is usable');
	like($H->openbao_static_key_problem("$KEY_A\n"), qr/surrounding whitespace \(65 characters stored\).*printf %s/,
		'a trailing newline is caught and printf %s is named');
	like($H->openbao_static_key_problem(" $KEY_A"), qr/surrounding whitespace/, 'leading whitespace too');
	like($H->openbao_static_key_problem(uc $KEY_A), qr/not lowercase hex/, 'uppercase is rejected');
	like($H->openbao_static_key_problem('0a' x 16), qr/32 characters long, not 64/, 'a short key');
	like($H->openbao_static_key_problem(''), qr/empty/, 'an empty key');
	for my $k ("$KEY_A\n", uc($KEY_A), '0a' x 16) {
		unlike($H->openbao_static_key_problem($k), qr/0a0a|0A0A/, 'the message never quotes the key');
	}
};

subtest 'derived key id matches the release' => sub {
	# The release's own test vector (spec/config/openbao_hcl_test.rb) for
	# 32 bytes of 0x0a.
	is($H->openbao_static_key_id($KEY_A), 'sha256-b9b07dd4e7718454', 'release test vector');
	is($H->openbao_static_key_id("$KEY_A\n"), undef, 'no id for a malformed key');
};

# --- (e) check hook -----------------------------------------------------

sub run_check {
	my (%o) = @_;
	my $hook = Test::CheckHook->new(Test::FakeEnv->new(%o));
	my ($ok, $out) = capture { $hook->check_openbao_seal };
	return ($ok, $out);
}

subtest 'check hook' => sub {
	my $base = 'secret/test/bosh/openbao/seal';
	my ($ok, $out) = run_check(features => ['vsphere']);
	ok($ok, 'an env without openbao passes');
	is($out, '', 'and is not mentioned at all');

	($ok, $out) = run_check(exodus => {has_openbao => 1});
	ok(!$ok, 'an existing env without the param fails');
	like($out, qr/openbao_seal: shamir.*openbao_seal: static/s, 'and names both choices');

	($ok, $out) = run_check(params => {openbao_seal => 'auto'});
	ok(!$ok, 'an invalid value fails');

	($ok, $out) = run_check(params => {openbao_seal => 'shamir', openbao_seal_static_disabled => 1});
	ok(!$ok, 'the static disabled switch fails under shamir');

	($ok, $out) = run_check(params => {openbao_seal => 'shamir'});
	ok($ok, 'shamir passes');

	($ok, $out) = run_check(params => {openbao_seal => 'static'});
	ok($ok, 'static with no key yet passes');
	like($out, qr/warning.*add-secrets/s, 'with a warning that add-secrets generates it');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new("$base/static" => {key => $KEY_A}));
	ok($ok, 'static with a good key passes');
	unlike($out, qr/0a0a/, 'without printing the key');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new("$base/static" => {key => "$KEY_A\n"}));
	ok(!$ok, 'a stored key with a trailing newline fails');
	like($out, qr/surrounding whitespace/, 'and says why');
	unlike($out, qr/0a0a/, 'without printing the key');

	($ok, $out) = run_check(exodus => {has_openbao => 1, openbao_seal => 'static'},
		vault => Test::FakeVault->new("$base/static" => {key => $KEY_A}));
	ok($ok, 'a recorded static env without the param passes');
	like($out, qr/warning.*kept from|warning.*last deployed/s, 'with a warning asking for the param');

	my $id_b = $H->openbao_static_key_id($KEY_B);
	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new(
			"$base/static" => {key => $KEY_A},
			"$base/static-previous" => {key => $KEY_B, id => $id_b}));
	ok($ok, 'a rotation with a matching previous id passes');
	like($out, qr/rotation in progress/, 'and reports the rotation');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new(
			"$base/static" => {key => $KEY_A},
			"$base/static-previous" => {key => $KEY_B, id => 'sha256-0000000000000000'}));
	ok(!$ok, 'a previous id that does not match the previous key fails');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new(
			"$base/static" => {key => $KEY_A},
			"$base/static-previous" => {key => $KEY_B}));
	ok(!$ok, 'a previous key without an id fails');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new(
			"$base/static" => {key => $KEY_A},
			"$base/static-previous" => {key => "$KEY_B\n", id => $id_b}));
	ok(!$ok, 'a previous key with a trailing newline fails');
	unlike($out, qr/0b0b/, 'without printing it');
};

# --- (f) openbao_request keeps secrets off command lines ---------------

subtest 'openbao_request sends secrets on stdin only' => sub {
	my @calls;
	no warnings qw/redefine once/;
	local *Genesis::Hook::Features::BOSH::run = sub {
		my $opts = ref($_[0]) eq 'HASH' ? shift : {};
		push @calls, {opts => $opts, argv => [@_]};
		return ("{\"ok\":true}\n200", 0, '');
	};
	my $env = Test::FakeEnv->new(params => {static_ip => '10.0.0.5'});

	my ($code, $body) = $H->openbao_request($env, method => 'POST', path => 'sys/mounts/secret',
		token => 's.ROOTTOKEN', body => '{"type":"kv"}');
	is($code, '200', 'returns the HTTP code');
	is($body, '{"ok":true}', 'and the body');
	my $argv = join(' ', @{$calls[-1]{argv}});
	unlike($argv, qr/ROOTTOKEN/, 'the token is not on the command line');
	like($calls[-1]{opts}{stdin}, qr/^X-Vault-Token: s\.ROOTTOKEN\n\z/, 'it is a header on stdin');
	like($argv, qr/-H \@- /, 'curl reads headers from stdin');
	like($argv, qr{https://10\.0\.0\.5:8200/v1/sys/mounts/secret$}, 'the URL is built from the params');

	$H->openbao_request($env, method => 'PUT', path => 'sys/unseal', stdin_body => '{"key":"SECRETKEY"}');
	$argv = join(' ', @{$calls[-1]{argv}});
	unlike($argv, qr/SECRETKEY/, 'a secret body is not on the command line');
	is($calls[-1]{opts}{stdin}, '{"key":"SECRETKEY"}', 'it goes on stdin');
	like($argv, qr/--data-binary \@-/, 'curl reads the body from stdin');
	ok($calls[-1]{opts}{redact_output}, 'the response is redacted from debug output');

	ok(!eval { $H->openbao_request($env, path => 'x', token => 't', stdin_body => 'b'); 1 },
		'a token and a secret body together are refused');
};

# --- (g) static init ----------------------------------------------------

package Test::InitHelpers;
our @ISA = ('Genesis::Hook::Features::BOSH');
our @calls;
my %canned = (
	'sys/init' => ['200', JSON::PP->new->encode({
		recovery_keys_base64 => [map {"RECOVERY$_"} 1 .. 5],
		recovery_keys => [map {"hex$_"} 1 .. 5],
		root_token => 's.INITROOT',
	})],
	'sys/health'          => ['200', '{}'],
	'sys/mounts/secret'   => ['204', ''],
	'secret/data/handshake' => ['200', '{}'],
);
sub openbao_request {
	my ($class, $env, %o) = @_;
	push @calls, {%o};
	return @{$canned{$o{path}} || ['404', '{"errors":["no"]}']};
}

package Test::InitHook;
our @ISA = ('Genesis::Hook::Addon::BOSH::OpenbaoInit');
sub new   { my ($class, $env) = @_; return bless {env => $env}, $class }
sub vault { return $_[0]->{env}->vault }

package main;

subtest 'static init' => sub {
	my $vault = Test::FakeVault->new;
	my $hook = Test::InitHook->new(Test::FakeEnv->new(
		params => {openbao_seal => 'static', static_ip => '10.0.0.5'}, vault => $vault));
	@Test::InitHelpers::calls = ();
	my ($ok, $out, $err) = capture { $hook->_init_static('https://10.0.0.5:8200', 'Test::InitHelpers', '/ca.pem') };
	is($err, '', 'init completes') or diag $err;

	my ($init) = grep {$_->{path} eq 'sys/init'} @Test::InitHelpers::calls;
	is($init->{stdin_body}, '{"recovery_shares":5,"recovery_threshold":3}', 'asks for 5 recovery shares, threshold 3, on stdin');
	is($init->{ca_file}, '/ca.pem', 'and verifies TLS against the OpenBao CA');

	my ($import) = grep {$_->{args}[0] eq 'import'} @{$vault->{queries}};
	ok($import, 'the custody copy is written with safe import');
	unlike(join(' ', @{$import->{args}}), qr/RECOVERY|INITROOT/, 'no key or token on the command line');
	is_deeply($vault->{secrets}{'secret/test/bosh/openbao/seal/keys'},
		{(map {("key$_" => "RECOVERY$_")} 1 .. 5), kind => 'recovery'},
		'the recovery keys are stored at the custody path with kind recovery');
	is_deeply($vault->{secrets}{'secret/test/bosh/openbao/root_token'}, {token => 's.INITROOT'},
		'the root token is stored at the custody path');

	is(scalar(() = $out =~ /RECOVERY3/g), 1, 'each recovery key is printed exactly once');
	is(scalar(() = $out =~ /s\.INITROOT/g), 1, 'the root token is printed exactly once');

	my ($mount) = grep {$_->{path} eq 'sys/mounts/secret'} @Test::InitHelpers::calls;
	is($mount->{body}, '{"type":"kv","options":{"version":"2"}}', 'secret/ is mounted as KV v2');
	is($mount->{token}, 's.INITROOT', 'with the root token passed as a token (stdin header)');
	ok((grep {$_->{path} eq 'secret/data/handshake'} @Test::InitHelpers::calls), 'and the handshake is written');
};

# --- (h) unseal ---------------------------------------------------------

package Test::UnsealHelpers;
our @ISA = ('Genesis::Hook::Features::BOSH');
our (@calls, $status, @unseal_responses);
sub openbao_ca_file     { return undef }
sub openbao_seal_status { return $status }
sub openbao_request {
	my ($class, $env, %o) = @_;
	push @calls, {%o};
	return ('200', JSON::PP->new->encode(shift(@unseal_responses) || {sealed => JSON::PP::true}));
}

package Test::UnsealHook;
our @ISA = ('Genesis::Hook::Addon::BOSH::OpenbaoUnseal');
sub new   { my ($class, $env) = @_; return bless {env => $env}, $class }
sub vault { return $_[0]->{env}->vault }
sub openbao_seal_helpers { return 'Test::UnsealHelpers' }

package main;

subtest 'unseal' => sub {
	my $env = Test::FakeEnv->new(
		params => {openbao_seal => 'static', static_ip => '10.0.0.5'},
		vault  => Test::FakeVault->new('secret/test/bosh/openbao/seal/keys' =>
			{(map {("key$_" => "RK$_")} 1 .. 5), kind => 'recovery'}));
	my $hook = Test::UnsealHook->new($env);

	local $Test::UnsealHelpers::status = {type => 'static', sealed => JSON::PP::false};
	my ($ok, $out, $err) = capture { $hook->perform };
	ok($ok, 'an unsealed server needs nothing');

	local $Test::UnsealHelpers::status = {type => 'shamir', sealed => JSON::PP::true, migration => JSON::PP::true};
	@Test::UnsealHelpers::calls = ();
	($ok, $out, $err) = capture { $hook->perform };
	like($err.$out, qr/seal migration pending/, 'a pending migration is explained');
	is(scalar(@Test::UnsealHelpers::calls), 0, 'and no key is sent');

	local $Test::UnsealHelpers::status = {type => 'static', sealed => JSON::PP::true, t => 3};
	no warnings 'redefine';
	local *Genesis::Hook::Addon::BOSH::OpenbaoUnseal::in_controlling_terminal = sub { 0 };
	($ok, $out, $err) = capture { $hook->perform };
	like($out, qr/monit\s+restart\s+openbao/, 'a sealed static server gets the restart advice');
	like($err.$out, qr/interactive terminal/, 'and a non-interactive run stops there');
	is(scalar(@Test::UnsealHelpers::calls), 0, 'without sending any key');

	local *Genesis::Hook::Addon::BOSH::OpenbaoUnseal::in_controlling_terminal = sub { 1 };
	local *Genesis::Hook::Addon::BOSH::OpenbaoUnseal::prompt_for_boolean = sub { 0 };
	($ok, $out, $err) = capture { $hook->perform };
	ok(!$ok, 'declining the manual-seal confirmation does not unseal');
	is(scalar(@Test::UnsealHelpers::calls), 0, 'and sends no key');

	local *Genesis::Hook::Addon::BOSH::OpenbaoUnseal::prompt_for_boolean = sub { 1 };
	local @Test::UnsealHelpers::unseal_responses = (
		{sealed => JSON::PP::true, progress => 1, t => 3},
		{sealed => JSON::PP::true, progress => 2, t => 3},
		{sealed => JSON::PP::false},
	);
	($ok, $out, $err) = capture { $hook->perform };
	ok($ok, 'a confirmed manual seal is unsealed with the recovery keys') or diag $err;
	is(scalar(@Test::UnsealHelpers::calls), 3, 'stopping once the server reports unsealed');
	is_deeply([map {$_->{path}} @Test::UnsealHelpers::calls], [('sys/unseal') x 3], 'each through sys/unseal');
	is_deeply([map {JSON::PP->new->decode($_->{stdin_body})->{key}} @Test::UnsealHelpers::calls],
		[qw/RK1 RK2 RK3/], 'one key per request, on stdin');
	unlike($out, qr/RK\d/, 'no key is printed');
};

# --- (i) post-deploy seal type check ----------------------------------

package Test::PostDeployHelpers;
our @ISA = ('Genesis::Hook::Features::BOSH');
our $status;
sub openbao_seal_status { return $status }

package Test::PostDeployHook;
our @ISA = ('Genesis::Hook::PostDeploy::BOSH');
sub new { my ($class, $env) = @_; return bless {env => $env}, $class }
sub openbao_seal_helpers { return 'Test::PostDeployHelpers' }

package main;

subtest 'post-deploy seal type check' => sub {
	my $static = Test::PostDeployHook->new(Test::FakeEnv->new(params => {openbao_seal => 'static'}));
	local $Test::PostDeployHelpers::status = {type => 'static', sealed => JSON::PP::false};
	my ($r) = capture { $static->_check_openbao_seal_type };
	is($r, 1, 'a static server under static mode passes');

	local $Test::PostDeployHelpers::status = {type => 'shamir', sealed => JSON::PP::false};
	my ($r2, $out) = capture { $static->_check_openbao_seal_type };
	is($r2, 0, 'a shamir server under static mode fails (release 0.3.x ignored the seal)');
	like($out, qr/shamir.*static/s, 'naming both types');

	local $Test::PostDeployHelpers::status = {type => 'static', sealed => JSON::PP::true, migration => JSON::PP::true};
	my $shamir = Test::PostDeployHook->new(Test::FakeEnv->new(params => {openbao_seal => 'shamir'}));
	($r) = capture { $shamir->_check_openbao_seal_type };
	is($r, 1, 'a pending migration passes');

	local $Test::PostDeployHelpers::status = undef;
	($r) = capture { $static->_check_openbao_seal_type };
	is($r, undef, 'an unreachable server is a noop');

	my $none = Test::PostDeployHook->new(Test::FakeEnv->new(features => ['vsphere']));
	($r) = capture { $none->_check_openbao_seal_type };
	is($r, undef, 'an env without openbao is a noop');
};

done_testing;
