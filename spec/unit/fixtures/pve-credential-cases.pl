# The cases the PVE credential rule is tested against.  Both backstops use
# the same rule, so both are driven by this one table: the final check in
# hooks/cpi-config.pm, through pve_credential_violations, and the inline
# director-cpi scan in hooks/post-deploy.pm.
#
# Each case is a PVE cpi config's properties, as the rule sees them after
# evaluation.  Refused cases name the node the error has to point at.  Every
# reference is absolute, because the inline upload accepts only those, and
# every credential is synthetic.
#
# Returns { refused => [[path, properties], ...],
#           accepted => [[what, properties], ...] }.
use strict;
use warnings;

my $ref = '((/cpi-config/properties/pve-api-token-az1))';
my %host = (host => '10.0.0.1', user => 'kit-test@pve', node => 'pve-unit-0');
my %set  = (names => ['nfs-e'], strategy => { name => 'spread', version => 1 });

+{
	refused => [
		['pve.api_token',            { pve => { %host, api_token => 'SYNTHETIC-TOKEN' } }],
		['pve.password',             { pve => { %host, password => 'SYNTHETIC-PASSWORD' } }],
		['pve_api_token',            { pve => { %host }, pve_api_token => 'SYNTHETIC-TOKEN' }],
		['pve_password',             { pve => { %host }, pve_password => 'SYNTHETIC-PASSWORD' }],
		['pve.password',             { pve => { %host, password => { value => 'SYNTHETIC-PASSWORD' } } }],
		['pve_password',             { pve => { %host }, pve_password => { value => 'SYNTHETIC-PASSWORD' } }],
		['pve.api_token',            { pve => { %host, api_token => ['SYNTHETIC-TOKEN'] } }],
		# The CPI checks whether a credential key is present, so a null beside a
		# token reference fails every CPI call with "expected string, got <nil>".
		['pve.password',             { pve => { %host, api_token => $ref, password => undef } }],
		['pve.lb_register.password', { pve => { %host, api_token => $ref, lb_register => { password => 'SYNTHETIC-LB-PASSWORD' } } }],
		['pve_proxy_password',       { pve => { %host, api_token => $ref }, pve_proxy_password => 'SYNTHETIC-PROXY' }],
		['pve.proxy_secret',         { pve => { %host, api_token => $ref, proxy_secret => 'SYNTHETIC-PROXY' } }],
		['agent.mbus',               { pve => { %host, api_token => $ref }, agent => { mbus => 'nats://u:SYNTHETIC-NATS@10.0.0.4:4222' } }],
		['pve_agent_mbus',           { pve => { %host, api_token => $ref }, pve_agent_mbus => 'nats://u:SYNTHETIC-NATS@10.0.0.4:4222' }],
	],
	accepted => [
		['a nested token reference',  { pve => { %host, api_token => $ref } }],
		['a flat token reference',    { pve => { %host }, pve_api_token => '((/director/credhub/genesis-entombed/cpi-config-property--pve_api_token--00000000))' }],
		['a flat password reference', { pve => { %host }, pve_password => '((/cpi-config/properties/pve-password-az1))' }],
		['a storage set named secret', { pve => { %host, api_token => $ref }, pve_storage_sets => { secret => { %set } } }],
		['a nested storage set named password', { pve => { %host, api_token => $ref, storage_sets => { password => { %set } } } }],
		['an mbus URL with a referenced password', { pve => { %host, api_token => $ref }, agent => { mbus => 'nats://u:((/x/nats-password))@10.0.0.4:4222' } }],
	],
};
