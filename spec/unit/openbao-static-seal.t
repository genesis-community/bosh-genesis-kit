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
#       invalid values, and never dying.  Static is the default only for an
#       env the vault proves is new, and nothing contacts OpenBao.
#   (c) key validation catches surrounding whitespace (OpenBao 2.7 does not
#       trim the key file) without quoting the value.
#   (d) the derived key id matches the release's test vector.
#   (e) the check hook passes, warns, or fails each case without printing a
#       key, checks the previous key's id during a rotation, refuses a key
#       whose id differs from the one the server last unsealed with, and
#       refuses to start the static seal without a verified escrow.
#   (f) openbao_request sends tokens and secret bodies on stdin only.
#   (g) static init backs up the recovery keys through stdin, prints them
#       exactly once, and mounts secret/ as KV v2; earlier custody keys are
#       copied aside and verified before any init.
#   (h) unseal refuses a pending migration and a non-interactive static
#       unseal without sending keys, and sends recovery keys one at a time
#       on stdin once a manual seal is confirmed.
#   (i) the post-deploy seal type check passes, fails, and skips correctly,
#       accepts a pending migration only under an explicit param, and
#       records the running key's id in the exodus data.
#   (j) rotation keeps the old key and its derived id before generating a
#       new one, escrows both with a hash check, resumes a partial start,
#       compares escrow targets by vault rather than by name, and removes the
#       previous key only on a finish that every safety check allows.
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
require "$root/hooks/addon-openbao-rotate-seal-key~ork.pm";

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
# a command line and what went through stdin.  An unreachable vault answers
# like safe does: `exists` exits 1 with an error message, and has() and
# initialized() are false.
sub new { my ($class, %s) = @_; return bless {secrets => {%s}, queries => [], has_calls => 0}, $class }
sub unreachable { $_[0]->{unreachable} = 1; return $_[0] }
sub has {
	my ($self, $path, $key) = @_;
	$self->{has_calls}++;
	return 0 if $self->{unreachable};
	$path =~ s{^/+}{};
	return 0 unless exists $self->{secrets}{$path};
	return defined($key) ? exists($self->{secrets}{$path}{$key}) : 1;
}
sub initialized { return $_[0]->{unreachable} ? 0 : 1 }
sub name { return 'deploying' }
sub url  { return 'https://deploying.example:8200' }
sub get {
	my ($self, $path, $key) = @_;
	$path =~ s{^/+}{};
	my $data = $self->{secrets}{$path} or return defined($key) ? undef : {};
	return defined($key) ? $data->{$key} : {%$data};
}
sub query {
	my ($self, $opts, @args) = @_;
	push @{$self->{queries}}, {opts => {%$opts}, args => [@args]};
	return ('', 1, "Error: connection refused\n") if $self->{unreachable};
	my $path = defined($args[1]) ? $args[1] =~ s{^/+}{}r : undef;
	if ($args[0] eq 'exists') {
		return ('', 1, "Error: permission denied\n") if $self->{exists_errors};
		return ('', exists($self->{secrets}{$path}) ? 0 : 1, '');
	}
	if ($args[0] eq 'export') {
		return ('', 1) unless exists $self->{secrets}{$path};
		return (JSON::PP->new->encode({$path => $self->{secrets}{$path}}), 0);
	}
	if ($args[0] eq 'set') {
		for my $pair (@args[2 .. $#args]) {
			my ($k, $v) = split /=/, $pair, 2;
			$self->{secrets}{$path}{$k} = $v;
		}
		return ('', 0, '');
	}
	if ($args[0] eq 'gen') {
		my ($gpath, $key) = @args[-2, -1];
		$self->{secrets}{$gpath}{$key} = $self->{gen_value} // ('0c' x 32);
		return ('', 0);
	}
	if ($args[0] eq 'rm') {
		delete $self->{secrets}{$args[-1]};
		return ('', 0);
	}
	if ($args[0] eq 'import') {
		return ('', 1, "Error: permission denied\n") if $self->{import_fails};
		my $data = JSON::PP->new->decode($opts->{stdin});
		$self->{secrets}{$_} = $data->{$_} for keys %$data;
		return ('', 0);
	}
	return ('', 1);
}

package Test::FakeEnv;
# The exodus data lives in the fake vault at the env's exodus path, and
# exodus_lookup behaves like Genesis's: it returns the default, and never
# dies, when the path is missing or the vault cannot be read.
our $EXODUS = 'secret/exodus/test/bosh';
sub new {
	my ($class, %o) = @_;
	my $vault = $o{vault} // Test::FakeVault->new;
	$vault->{secrets}{$EXODUS} = {%{$o{exodus}}} if $o{exodus};
	return bless {
		params   => $o{params} // {},
		features => $o{features} // ['openbao'],
		vault    => $vault,
	}, $class;
}
sub lookup {
	my ($self, $key, $default) = @_;
	$key =~ s/^params\.// or return $default;
	return exists $self->{params}{$key} ? $self->{params}{$key} : $default;
}
sub exodus_lookup {
	my ($self, $key, $default) = @_;
	return $default unless $self->{vault}->has("/$EXODUS");
	my $data = $self->{vault}->get($EXODUS);
	return $data if $key eq '.';
	return exists $data->{$key} ? $data->{$key} : $default;
}
sub exodus_base  { return "/$EXODUS" }
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
	return ($result[0], $out =~ s/\e\[[0-9;]*m//gr, $err =~ s/\e\[[0-9;]*m//gr);
}

# Fresh state per env: openbao_seal_state memoizes on the env object.
sub state_for { return $H->openbao_seal_state(Test::FakeEnv->new(@_)) }

# Nothing in the seal mode decision or the check hook may contact OpenBao.
# These record any attempt, so the tests can prove that none happened.
our @NETWORK;
my $real_request = \&Genesis::Hook::Features::BOSH::openbao_request;
{
	no warnings qw/redefine once/;
	*Genesis::Hook::Features::BOSH::openbao_request = sub {
		push @NETWORK, {@_[2 .. $#_]};
		return (undef, 'no network in tests');
	};
}

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
	local @NETWORK = ();
	my $s = state_for(params => {openbao_seal => 'static'});
	is_deeply([@$s{qw/mode valid source/}], ['static', 1, 'param'], 'param static');
	$s = state_for(params => {openbao_seal => 'shamir'}, exodus => {openbao_seal => 'static'});
	is_deeply([@$s{qw/mode valid source/}], ['shamir', 1, 'param'], 'the param wins over the exodus record');
	$s = state_for(params => {openbao_seal => 'auto'});
	is_deeply([@$s{qw/mode valid/}], ['shamir', 0], 'an invalid value renders shamir and is flagged');
	$s = state_for(params => {openbao_seal => ['static']});
	is_deeply([@$s{qw/mode valid/}], ['shamir', 0], 'a non-scalar value is flagged');

	my $vault = Test::FakeVault->new;
	$s = state_for(params => {openbao_seal => 'static'}, vault => $vault);
	is($vault->{has_calls} + scalar(@{$vault->{queries}}), 0, 'with the param set, the vault is not read');

	$s = state_for(exodus => {has_openbao => 1, openbao_seal => 'static'});
	is_deeply([@$s{qw/mode source/}], ['static', 'exodus'], 'the recorded mode is kept without the param');
	$s = state_for(exodus => {has_openbao => 1});
	is_deeply([@$s{qw/mode source/}], ['shamir', 'existing-default'],
		'an env with exodus data but no seal record keeps shamir');
	like($s->{reason}, qr/deployed before/, 'because it has been deployed before');
	$s = state_for(exodus => {kit_version => '3.0.0'});
	is($s->{mode}, 'shamir', 'any exodus data counts as deployed, with or without has_openbao');

	$s = state_for(vault => Test::FakeVault->new->unreachable);
	is_deeply([@$s{qw/mode source/}], ['shamir', 'existing-default'],
		'an unreachable vault cannot prove the env is new, so shamir');
	like($s->{reason}, qr/could\s+not\s+prove/, 'and the reason says so');
	my $noisy = Test::FakeVault->new; $noisy->{exists_errors} = 1;
	$s = state_for(vault => $noisy);
	is($s->{mode}, 'shamir', 'an exists check that errors is not proof either');

	$s = state_for();
	is_deeply([@$s{qw/mode source/}], ['static', 'new-default'],
		'a reachable vault with no exodus path proves the env new, so static');
	is(scalar(@NETWORK), 0, 'no decision contacted OpenBao');

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
	local @NETWORK = ();
	my $base = 'secret/test/bosh/openbao/seal';
	my $id_a = $H->openbao_static_key_id($KEY_A);
	my $id_b = $H->openbao_static_key_id($KEY_B);
	my $escrow_a = {target => 'inception', url => 'https://inception.example:8200', id => $id_a};

	my $plain = Test::FakeVault->new;
	my ($ok, $out) = run_check(features => ['vsphere'], vault => $plain);
	ok($ok, 'an env without openbao passes');
	is($out, '', 'and is not mentioned at all');
	is($plain->{has_calls} + scalar(@{$plain->{queries}}), 0, 'and makes no vault call');

	($ok, $out) = run_check(exodus => {has_openbao => 1});
	ok(!$ok, 'an existing env without the param fails');
	like($out, qr/openbao_seal: shamir.*openbao_seal: static/s, 'and names both choices');

	($ok, $out) = run_check(vault => Test::FakeVault->new->unreachable);
	ok(!$ok, 'an env that cannot be proven new fails without the param');
	like($out, qr/could\s+not\s+prove/, 'and says why');

	($ok, $out) = run_check(params => {openbao_seal => 'auto'});
	ok(!$ok, 'an invalid value fails');

	($ok, $out) = run_check(params => {openbao_seal => 'shamir', openbao_seal_static_disabled => 1});
	ok(!$ok, 'the static disabled switch fails under shamir');
	($ok, $out) = run_check(params => {openbao_seal => 'shamir', openbao_seal_static_disabled => 0});
	ok($ok, 'a false static disabled switch is accepted under shamir');

	($ok, $out) = run_check(params => {openbao_seal => 'shamir'});
	ok($ok, 'shamir passes');

	($ok, $out) = run_check(params => {openbao_seal => 'static'});
	ok($ok, 'static with no key and no running static server passes');
	like($out, qr/warning.*add-secrets.*escrow/s, 'with a warning naming add-secrets and escrow');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new("$base/static" => {key => $KEY_A}));
	ok(!$ok, 'starting the static seal without an escrow record fails');
	like($out, qr/no verified escrow.*\Q$id_a\E.*openbao-rotate-seal-key\s+escrow/s,
		'naming the key id and the escrow command');
	unlike($out, qr/0a0a/, 'without printing the key');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new("$base/static" => {key => $KEY_A},
			"$base/escrow" => {%$escrow_a, id => $id_b}));
	ok(!$ok, 'an escrow record for a different key fails');
	like($out, qr/names\s+key\s+id\s+\Q$id_b\E/, 'and names the id it holds');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new("$base/static" => {key => $KEY_A}, "$base/escrow" => $escrow_a));
	ok($ok, 'starting the static seal with a matching escrow record passes');
	like($out, qr/escrow\s+verified/, 'and says the escrow is verified');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		exodus => {openbao_seal => 'static', openbao_static_key_id => $id_a},
		vault => Test::FakeVault->new("$base/static" => {key => $KEY_A}));
	ok($ok, 'a running static server whose recorded id matches the key passes');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		exodus => {openbao_seal => 'static', openbao_static_key_id => $id_b},
		vault => Test::FakeVault->new("$base/static" => {key => $KEY_A}, "$base/escrow" => $escrow_a));
	ok(!$ok, 'a key whose id differs from the one the server last unsealed with fails');
	like($out, qr/derives\s+to\s+id\s+\Q$id_a\E.*last\s+unsealed\s+with\s+key\s+id\s+\Q$id_b\E/s, 'naming both ids');
	unlike($out, qr/0a0a|0b0b/, 'without printing a key');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		exodus => {openbao_seal => 'static', openbao_static_key_id => $id_b});
	ok(!$ok, 'a missing key fails once a static server is on record');
	like($out, qr/not\s+in\s+the\s+vault.*\Q$id_b\E/s, 'and names the key id to restore');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new("$base/static" => {key => "$KEY_A\n"}));
	ok(!$ok, 'a stored key with a trailing newline fails');
	like($out, qr/surrounding whitespace/, 'and says why');
	unlike($out, qr/0a0a/, 'without printing the key');

	($ok, $out) = run_check(exodus => {openbao_seal => 'static', openbao_static_key_id => $id_a},
		vault => Test::FakeVault->new("$base/static" => {key => $KEY_A}));
	ok($ok, 'a recorded static env without the param passes');
	like($out, qr/warning.*last deployed with/s, 'with a warning asking for the param');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		exodus => {openbao_seal => 'static', openbao_static_key_id => $id_b},
		vault => Test::FakeVault->new(
			"$base/static" => {key => $KEY_A},
			"$base/static-previous" => {key => $KEY_B, id => $id_b}));
	ok($ok, 'a rotation whose previous key is the recorded one passes');
	like($out, qr/rotation in progress/, 'and reports the rotation');

	($ok, $out) = run_check(params => {openbao_seal => 'static'},
		exodus => {openbao_seal => 'static', openbao_static_key_id => $id_b},
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
	is(scalar(@NETWORK), 0, 'the check hook never contacted OpenBao');
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
	local *Genesis::Hook::Features::BOSH::openbao_request = $real_request;
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

subtest 'init keeps earlier custody keys' => sub {
	my $base = 'secret/test/bosh/openbao';
	my $old_keys = {(map {("key$_" => "OLDKEY$_")} 1 .. 5), kind => 'shamir'};
	my $vault = Test::FakeVault->new("$base/seal/keys" => $old_keys, "$base/root_token" => {token => 's.OLDROOT'});
	my $hook = Test::InitHook->new(Test::FakeEnv->new(params => {openbao_seal => 'static'}, vault => $vault));
	my ($ok, $out, $err) = capture { $hook->_preserve_custody_paths($H) };
	is($err, '', 'existing custody keys are copied aside') or diag $err;
	my ($keys_aside)  = grep {m{^\Q$base\E/seal/keys-\d{8}T\d{6}Z$}} keys %{$vault->{secrets}};
	my ($token_aside) = grep {m{^\Q$base\E/root_token-\d{8}T\d{6}Z$}} keys %{$vault->{secrets}};
	ok($keys_aside, 'the keys go to a timestamped path');
	is_deeply($vault->{secrets}{$keys_aside}, $old_keys, 'with the same contents');
	is_deeply($vault->{secrets}{$token_aside}, {token => 's.OLDROOT'}, 'and so does the root token');
	is_deeply($vault->{secrets}{"$base/seal/keys"}, $old_keys, 'the original path is left for init to replace');
	unlike($out, qr/OLDKEY|OLDROOT/, 'no key or token is printed');
	unlike(join(' ', map {@{$_->{args}}} @{$vault->{queries}}), qr/OLDKEY|OLDROOT/,
		'no key or token reaches a command line');

	my $failing = Test::FakeVault->new("$base/seal/keys" => $old_keys);
	$failing->{import_fails} = 1;
	$hook = Test::InitHook->new(Test::FakeEnv->new(params => {openbao_seal => 'static'}, vault => $failing));
	($ok, $out, $err) = capture { $hook->_preserve_custody_paths($H) };
	like($err, qr/Could not copy.*not\s+initializing/s, 'a failed copy stops init');

	my $empty = Test::FakeVault->new;
	$hook = Test::InitHook->new(Test::FakeEnv->new(params => {openbao_seal => 'static'}, vault => $empty));
	($ok, $out, $err) = capture { $hook->_preserve_custody_paths($H) };
	ok($ok, 'a vault with no earlier keys needs no copy');
	is(scalar(grep {$_->{args}[0] eq 'import'} @{$empty->{queries}}), 0, 'and writes nothing');
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
	my $base = 'secret/test/bosh/openbao/seal';
	my $id_a = $H->openbao_static_key_id($KEY_A);
	my $vault = Test::FakeVault->new("$base/static" => {key => $KEY_A});
	my $static = Test::PostDeployHook->new(Test::FakeEnv->new(params => {openbao_seal => 'static'}, vault => $vault));
	local $Test::PostDeployHelpers::status = {type => 'static', sealed => JSON::PP::false};
	my ($r, $out) = capture { $static->_check_openbao_seal_type };
	is($r, 1, 'a static server under static mode passes');
	is($vault->{secrets}{$Test::FakeEnv::EXODUS}{openbao_static_key_id}, $id_a,
		'and the running key id is recorded in the exodus data');
	unlike($out.join(' ', map {@{$_->{args}}} @{$vault->{queries}}), qr/0a0a/, 'without the key reaching output or argv');

	my $sealed_vault = Test::FakeVault->new("$base/static" => {key => $KEY_A});
	my $sealed = Test::PostDeployHook->new(Test::FakeEnv->new(params => {openbao_seal => 'static'}, vault => $sealed_vault));
	local $Test::PostDeployHelpers::status = {type => 'static', sealed => JSON::PP::true};
	($r) = capture { $sealed->_check_openbao_seal_type };
	is($r, 1, 'a sealed static server passes the type check');
	ok(!$sealed_vault->{secrets}{$Test::FakeEnv::EXODUS}, 'but records no key id');

	local $Test::PostDeployHelpers::status = {type => 'shamir', sealed => JSON::PP::false};
	($r, $out) = capture { $static->_check_openbao_seal_type };
	is($r, 0, 'a shamir server under static mode fails (release 0.3.x ignored the seal)');
	like($out, qr/shamir.*static/s, 'naming both types');

	local $Test::PostDeployHelpers::status = {type => 'static', sealed => JSON::PP::true, migration => JSON::PP::true};
	my $explicit = Test::PostDeployHook->new(Test::FakeEnv->new(params => {openbao_seal => 'static'}));
	($r) = capture { $explicit->_check_openbao_seal_type };
	is($r, 1, 'a pending migration passes when params.openbao_seal chose it');

	my $defaulted = Test::PostDeployHook->new(Test::FakeEnv->new());
	($r, $out) = capture { $defaulted->_check_openbao_seal_type };
	is($r, 0, 'a pending migration fails when the mode came from the new-env default');
	like($out, qr/nobody\s+chose\s+this\s+migration/, 'and says how to back it out');

	my $recorded = Test::PostDeployHook->new(Test::FakeEnv->new(exodus => {openbao_seal => 'static'}));
	($r) = capture { $recorded->_check_openbao_seal_type };
	is($r, 0, 'and when it came from the exodus record');

	local $Test::PostDeployHelpers::status = undef;
	($r) = capture { $static->_check_openbao_seal_type };
	is($r, undef, 'an unreachable server is a noop');

	my $none = Test::PostDeployHook->new(Test::FakeEnv->new(features => ['vsphere']));
	($r) = capture { $none->_check_openbao_seal_type };
	is($r, undef, 'an env without openbao is a noop');
};

# --- (j) rotation -------------------------------------------------------

package Test::RotateHelpers;
our @ISA = ('Genesis::Hook::Features::BOSH');
our $status = {type => 'static', sealed => JSON::PP::false};
sub openbao_ca_file     { return undef }
sub openbao_seal_status { return $status }

package Test::RotateHook;
our @ISA = ('Genesis::Hook::Addon::BOSH::OpenbaoRotateSealKey');
sub new {
	my ($class, $env, $args, %opts) = @_;
	return bless {env => $env, args => $args, options => {%opts}}, $class;
}
sub vault { return $_[0]->{env}->vault }
sub openbao_seal_helpers { return 'Test::RotateHelpers' }
# safe targets and the cluster ids their vaults report.  "dupe" is the
# deploying vault under a differently spelled URL, and "alias" is the
# deploying vault under another address, told apart only by cluster id.
our %TARGETS = (
	inception => ['https://inception.example:8200'],
	dupe      => ['HTTPS://Deploying.example:8200/'],
	alias     => ['https://10.0.0.9:8200'],
	twice     => ['https://a.example:8200', 'https://b.example:8200'],
);
our %CLUSTER = (
	'https://inception.example:8200' => 'cluster-inception',
	'https://deploying.example:8200' => 'cluster-deploying',
	'https://10.0.0.9:8200'          => 'cluster-deploying',
);
sub _vault_targets_named {
	my ($self, $name) = @_;
	return map { {name => $name, url => $_} } @{$TARGETS{$name} || []};
}
sub _vault_cluster_id { return $CLUSTER{$_[1]} }

package main;

# escrow_run stands in for the safe processes that talk to the escrow vault.
our %ESCROW;
our @ESCROW_ARGV;
sub escrow_run {
	my $opts = ref($_[0]) eq 'HASH' ? shift : {};
	my (undef, undef, $target, $verb, $path) = @_;
	push @ESCROW_ARGV, join(' ', @_);
	if ($verb eq 'import') {
		my $data = JSON::PP->new->decode($opts->{stdin});
		$ESCROW{$target}{$_} = $data->{$_} for keys %$data;
		return ('', 0, '');
	}
	if ($verb eq 'export') {
		my $d = $ESCROW{$target}{$path} or return ('', 1, 'missing');
		return (JSON::PP->new->encode({$path => $d}), 0, '');
	}
	return ('', 1, 'unexpected');
}

subtest 'rotation' => sub {
	no warnings qw/redefine once/;
	local *Genesis::Hook::Addon::BOSH::OpenbaoRotateSealKey::run = \&escrow_run;
	local *Genesis::Hook::Addon::BOSH::OpenbaoRotateSealKey::in_controlling_terminal = sub { 0 };
	local %ESCROW = ();
	local @ESCROW_ARGV = ();
	my $base = 'secret/test/bosh/openbao/seal';
	my $id_a = $H->openbao_static_key_id($KEY_A);
	my $id_c = $H->openbao_static_key_id($KEY_C);
	my $vault = Test::FakeVault->new("$base/static" => {key => $KEY_A});
	my $env = Test::FakeEnv->new(params => {openbao_seal => 'static'}, vault => $vault,
		exodus => {openbao_seal => 'static', openbao_static_key_id => $id_a});
	my $rotate = sub { my ($args, %o) = @_; capture { Test::RotateHook->new($env, $args, %o)->perform } };

	my ($ok, $out, $err) = $rotate->(['start']);
	like($err, qr/--escrow-target.*--skip-escrow/s, 'start demands an escrow choice');
	is_deeply($vault->{secrets}{"$base/static"}, {key => $KEY_A}, 'and changes nothing');

	($ok, $out, $err) = $rotate->(['start'], 'escrow-target' => 'dupe');
	like($err, qr/vault this\s+environment deploys from/, 'a target with the deploying URL is refused, however it is spelled');
	($ok, $out, $err) = $rotate->(['start'], 'escrow-target' => 'alias');
	like($err, qr/same cluster id/, 'a target reporting the deploying cluster id is refused');
	($ok, $out, $err) = $rotate->(['start'], 'escrow-target' => 'nowhere');
	like($err, qr/No safe target named/, 'an unknown target is refused');
	($ok, $out, $err) = $rotate->(['start'], 'escrow-target' => 'twice');
	like($err, qr/More than one/, 'an ambiguous target is refused');
	ok(!$vault->{secrets}{"$base/static-previous"}, 'and none of them changed anything');

	($ok, $out, $err) = $rotate->(['start'], 'escrow-target' => 'inception');
	ok($ok, 'start completes') or diag $err;
	is_deeply($vault->{secrets}{"$base/static-previous"}, {key => $KEY_A, id => $id_a},
		'the old key and its derived id are kept as previous');
	is($vault->{secrets}{"$base/static"}{key}, $KEY_C, 'a new key is generated');
	is_deeply($ESCROW{inception}{"$base/static-previous"}, $vault->{secrets}{"$base/static-previous"},
		'the previous key is escrowed');
	is_deeply($ESCROW{inception}{"$base/static"}, {key => $KEY_C}, 'the new key is escrowed');
	my $record = $vault->{secrets}{"$base/escrow"};
	is_deeply([@$record{qw/target url cluster_id id previous_id/}],
		['inception', 'https://inception.example:8200', 'cluster-inception', $id_c, $id_a],
		'the escrow record names the target, its vault, and both key ids');
	like($record->{escrowed_at}, qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/, 'with a UTC time');
	unlike(join("\n", @ESCROW_ARGV), qr/0a0a|0c0c/, 'no key reaches an escrow command line');
	unlike(join("\n", map {join ' ', @{$_->{args}}} @{$vault->{queries}}), qr/0a0a|0c0c/,
		'no key reaches a deploying-vault command line');
	unlike($out, qr/0a0a|0c0c/, 'no key is printed');
	like($out, qr/post-unseal\s+upgrade\s+seal\s+keys\s+failed/, 'the next steps name the log line to check');
	my @order = map {$_->{args}[0]} grep {$_->{args}[0] =~ /^(import|gen)$/} @{$vault->{queries}};
	is_deeply([@order[0, 1]], [qw/import gen/], 'the previous key is stored before the new one is generated');

	($ok, $out, $err) = $rotate->(['start'], 'escrow-target' => 'inception');
	like($err, qr/already under way/, 'a second start is refused once the key changed');

	# finish: every safety check holds even with --yes.
	($ok, $out, $err) = $rotate->(['finish'], yes => 1, 'skip-escrow' => 1);
	like($err, qr/does not take/, 'finish refuses --skip-escrow');

	my $saved = delete $vault->{secrets}{"$base/escrow"};
	($ok, $out, $err) = $rotate->(['finish'], yes => 1);
	like($err, qr/no verified escrow/, 'finish refuses without an escrow record');
	$vault->{secrets}{"$base/escrow"} = {%$saved, id => $id_a};
	($ok, $out, $err) = $rotate->(['finish'], yes => 1);
	like($err, qr/no verified escrow/, 'and with a record for the old key');
	$vault->{secrets}{"$base/escrow"} = $saved;

	($ok, $out, $err) = $rotate->(['finish'], yes => 1);
	like($err, qr/No deploy has rendered both keys/, 'finish refuses before a deploy rendered both keys');

	my $exodus = $vault->{secrets}{$Test::FakeEnv::EXODUS};
	$exodus->{openbao_static_previous_key_id} = $id_a;
	($ok, $out, $err) = $rotate->(['finish'], yes => 1);
	like($err, qr/does not record the server running on the new key/,
		'finish refuses before the server came up unsealed on the new key');

	$exodus->{openbao_static_key_id} = $id_c;
	{
		local $Test::RotateHelpers::status = {type => 'static', sealed => JSON::PP::true};
		($ok, $out, $err) = $rotate->(['finish'], yes => 1);
		like($err, qr/sealed/, 'finish refuses a sealed server, even with --yes');
	}
	ok($vault->{secrets}{"$base/static-previous"}, 'none of the refusals removed the previous key');

	($ok, $out, $err) = $rotate->(['finish']);
	like($err, qr/--yes/, 'finish without a terminal needs --yes');
	ok($vault->{secrets}{"$base/static-previous"}, 'and keeps the previous key');
	($ok, $out, $err) = $rotate->(['finish'], yes => 1);
	ok($ok, 'finish --yes completes once every check holds') or diag $err;
	ok(!$vault->{secrets}{"$base/static-previous"}, 'and removes the previous key');
	like($out, qr/safe -T inception rm/, 'naming the escrow copy to remove later');

	# The escrow action on a running static env with no rotation.
	my $plain = Test::FakeVault->new("$base/static" => {key => $KEY_A});
	my $penv0 = Test::FakeEnv->new(params => {openbao_seal => 'static'}, vault => $plain);
	local %ESCROW = ();
	($ok, $out, $err) = capture { Test::RotateHook->new($penv0, ['escrow'])->perform };
	like($err, qr/needs\s+--escrow-target/, 'escrow needs a target');
	($ok, $out, $err) = capture { Test::RotateHook->new($penv0, ['escrow'], 'escrow-target' => 'dupe')->perform };
	like($err, qr/deploys from/, 'and refuses the deploying vault');
	ok(!$plain->{secrets}{"$base/escrow"}, 'without writing a record');
	($ok, $out, $err) = capture { Test::RotateHook->new($penv0, ['escrow'], 'escrow-target' => 'inception')->perform };
	ok($ok, 'escrow completes') or diag $err;
	is_deeply($ESCROW{inception}{"$base/static"}, {key => $KEY_A}, 'copying the key');
	is($plain->{secrets}{"$base/escrow"}{id}, $id_a, 'and recording its id');
	ok(!exists $plain->{secrets}{"$base/escrow"}{previous_id}, 'with no previous id outside a rotation');
	unlike($out, qr/0a0a/, 'without printing the key');

	# A start that stopped after storing the previous key resumes.
	my $partial = Test::FakeVault->new(
		"$base/static" => {key => $KEY_A},
		"$base/static-previous" => {key => $KEY_A, id => $id_a});
	my $penv = Test::FakeEnv->new(params => {openbao_seal => 'static'}, vault => $partial);
	($ok, $out, $err) = capture { Test::RotateHook->new($penv, ['start'], 'skip-escrow' => 1)->perform };
	ok($ok, 'a partial start resumes') or diag $err;
	is($partial->{secrets}{"$base/static"}{key}, $KEY_C, 'and generates the new key');
	like($out, qr/not\s+escrowed/, 'skipping escrow is called out');
	ok(!$partial->{secrets}{"$base/escrow"}, 'and no escrow record is written');

	# repair-id rewrites a wrong id.
	$partial->{secrets}{"$base/static-previous"}{id} = 'sha256-0000000000000000';
	($ok, $out, $err) = capture { Test::RotateHook->new($penv, ['repair-id'])->perform };
	ok($ok, 'repair-id completes') or diag $err;
	is($partial->{secrets}{"$base/static-previous"}{id}, $id_a, 'and stores the derived id');
	is($partial->{secrets}{"$base/static-previous"}{key}, $KEY_A, 'leaving the key as it was');

	local $Test::RotateHelpers::status = {type => 'static', sealed => JSON::PP::true};
	my $fresh = Test::FakeEnv->new(params => {openbao_seal => 'static'},
		vault => Test::FakeVault->new("$base/static" => {key => $KEY_A}));
	($ok, $out, $err) = capture { Test::RotateHook->new($fresh, ['start'], 'skip-escrow' => 1)->perform };
	like($err, qr/sealed/, 'start refuses a sealed server');

	my $shamir = Test::FakeEnv->new(params => {openbao_seal => 'shamir'}, vault => $vault);
	($ok, $out, $err) = capture { Test::RotateHook->new($shamir, ['start'], 'skip-escrow' => 1)->perform };
	like($err, qr/only a static seal/, 'a shamir env has nothing to rotate');
};

done_testing;
