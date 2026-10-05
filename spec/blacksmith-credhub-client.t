#!/usr/bin/env perl
# Direct assertions on the blacksmith_credhub UAA client that the
# blacksmith-integration addon creates for the Blacksmith broker's CredHub
# cleanup.
#
# The golden manifests under spec/results can be regenerated, and a
# regeneration would quietly bless a wider authority list or a longer token
# lifetime. This test therefore reads the addon overlay and kit.yml itself and
# compares them with values typed in below, so the grant types, authorities,
# scope, token lifetime, and secret source can only change by editing this
# file as well.
#
# Operators in the overlay (vault, grab) stay as literal strings, because the
# files are only converted to JSON here and never merged.
use strict;
use warnings;
use FindBin;
use JSON::PP;
use Test::More;

my $KIT     = "$FindBin::Bin/..";
my $ADDON   = "$KIT/overlay/addons/blacksmith-integration.yml";
my $CREDHUB = "$KIT/overlay/addons/credhub.yml";
my $KIT_YML = "$KIT/kit.yml";

# graft json converts a file without evaluating its operators.
sub load_yaml {
	my ($path) = @_;
	die "cannot find $path\n" unless -f $path;
	my $json = qx{graft json '$path' 2>&1};
	die "graft json failed on $path:\n$json\n" if $? != 0;
	return decode_json($json);
}

my $addon   = load_yaml($ADDON);
my $credhub = load_yaml($CREDHUB);
my $kit     = load_yaml($KIT_YML);

# The addon puts its UAA properties on the uaa job of the bosh instance group.
my ($group) = grep { $_->{name} eq 'bosh' } @{ $addon->{instance_groups} };
ok($group, 'the addon extends the bosh instance group') or BAIL_OUT('no bosh instance group');
my ($uaa) = grep { $_->{name} eq 'uaa' } @{ $group->{jobs} };
ok($uaa, 'the addon extends the uaa job') or BAIL_OUT('no uaa job');
my $clients = $uaa->{properties}{uaa}{clients} || {};

# --- the client itself ---------------------------------------------------------
is_deeply(
	[ sort keys %$clients ],
	[ qw/blacksmith blacksmith_credhub/ ],
	'the addon defines exactly the blacksmith and blacksmith_credhub clients'
);

my $client = $clients->{blacksmith_credhub} || {};

is_deeply(
	$client,
	{
		'access-token-validity'  => 300,
		'authorities'            => 'credhub.read,credhub.write',
		'authorized-grant-types' => 'client_credentials',
		'override'               => JSON::PP::true,
		'scope'                  => '',
		'secret'                 => '(( vault meta.vault "/users/blacksmith-credhub:password" ))',
	},
	'blacksmith_credhub carries exactly the expected properties and values'
);

# The same facts again, one by one, so a failure names the property.
is($client->{'authorized-grant-types'}, 'client_credentials',
	'client_credentials is the only grant type');
is($client->{scope}, '',
	'scope is empty, so the client cannot act as a user');
is($client->{'access-token-validity'}, 300,
	'the access token lasts 300 seconds');
ok($client->{override}, 'override is set so a redeploy resets the secret');
is($client->{secret}, '(( vault meta.vault "/users/blacksmith-credhub:password" ))',
	'the secret comes from /users/blacksmith-credhub:password');

# Any authority beyond credhub.read and credhub.write is a widening of what the
# broker can reach on the director, so name the offender when there is one.
my @authorities = split /,/, ($client->{authorities} // '');
is_deeply(
	[ sort @authorities ],
	[ qw/credhub.read credhub.write/ ],
	'the only authorities are credhub.read and credhub.write'
);
my %allowed = map { $_ => 1 } qw/credhub.read credhub.write/;
my @extra   = grep { !$allowed{$_} } @authorities;
is(scalar(@extra), 0, 'no extra authority' . (@extra ? ': ' . join(', ', @extra) : ''));

# --- the exodus keys -------------------------------------------------------------
# The Blacksmith kit reads these names, so they are spelled out here and in the
# golden manifests and nowhere else in this kit.
my $exodus = $addon->{exodus} || {};

is_deeply(
	[ sort grep { /^blacksmith_credhub_/ } keys %$exodus ],
	[ qw/
		blacksmith_credhub_ca_cert
		blacksmith_credhub_client_id
		blacksmith_credhub_client_secret
		blacksmith_credhub_director_name
	/ ],
	'the addon publishes exactly the four blacksmith_credhub_ exodus keys'
);

is_deeply(
	[ sort keys %$exodus ],
	[ qw/
		blacksmith_credhub_ca_cert
		blacksmith_credhub_client_id
		blacksmith_credhub_client_secret
		blacksmith_credhub_director_name
		blacksmith_password
		blacksmith_user
	/ ],
	'the addon publishes no other exodus keys'
);

is($exodus->{blacksmith_credhub_client_id}, 'blacksmith_credhub',
	'the exodus client id is the literal blacksmith_credhub');
is($exodus->{blacksmith_credhub_client_secret}, '(( vault meta.vault "/users/blacksmith-credhub:password" ))',
	'the exodus client secret is the same vault path the client uses');
is($exodus->{blacksmith_credhub_ca_cert}, '(( vault meta.vault "/credhub/ca:certificate" ))',
	'the exodus CA is the credhub CA certificate, not the pinned server certificate');
is($exodus->{blacksmith_credhub_director_name}, '(( grab name ))',
	'the exodus director name is the manifest name');

# The fifth key in the contract, the CredHub URL, already comes from the
# credhub overlay, and the integration addon must not redefine it.
ok(exists $credhub->{exodus}{credhub_url}, 'credhub_url is published by the credhub overlay');
ok(!exists $exodus->{credhub_url}, 'the integration addon leaves credhub_url alone');

# --- the generated secret --------------------------------------------------------
my $creds = $kit->{credentials}{'+blacksmith-credentials'} || {};
is_deeply(
	$creds->{'users/blacksmith-credhub'},
	{ password => 'random 64' },
	'kit.yml generates users/blacksmith-credhub:password as random 64'
);
is_deeply(
	$creds->{'users/blacksmith'},
	{ password => 'random 30' },
	'the existing users/blacksmith credential is unchanged'
);

done_testing;
