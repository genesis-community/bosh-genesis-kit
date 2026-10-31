package Genesis::Hook::CpiConfig::BOSH v4.3.0;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::CpiConfig);

use Genesis qw/bail info warning/;

# Genesis' default credhub_prefix for a director's own cpi config (see
# Genesis::Env::_cpi_config_data). The child config a parent director consumes
# is built with the environment's cpi_credhub_base instead, so the prefix is
# what distinguishes the two calls into this hook.
use constant DIRECTOR_CREDHUB_PREFIX => '/cpi-config/properties/';
use JSON::PP;

# Initialize hook object with necessary version checks
sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.15');
	return $obj;
}

# The CLI exports the canonical gcp path; the CPI release calls its job google.
sub iaas {
 my $self = shift;
 my $iaas = $self->SUPER::iaas;
 return $iaas eq 'google' ? 'gcp' : $iaas;
}

# The two PVE credentials. Their values are opaque strings, so they take
# their own resolver, below.
my %PVE_CREDENTIAL = map {($_ => 1)} qw(pve_password pve_api_token);

# The generic resolver decodes JSON values; google_cpi expects json_key to
# remain serialized JSON, including when stored as a CredHub value.
sub _resolve {
 my ($self, $spec, $routed) = @_;
 return $self->_resolve_pve_credential($spec, $routed)
   if $self->iaas eq 'pve' && $PVE_CREDENTIAL{$spec->{key}};
 my ($value, $found) = $self->SUPER::_resolve($spec, $routed);
 $value = JSON::PP->new->canonical->encode($value)
   if $self->iaas eq 'gcp' && $spec->{key} eq 'json_key' && ref($value) eq 'HASH';
 return ($value, $found);
}

# _resolve_pve_credential - Genesis' lookup order, reading vault as raw strings {{{
#
# This keeps the generic resolver's order and its rules: every operator name
# in bosh-configs.cpi before any OCFP name, the operator's value read through
# the lookup for the director the config goes to, and a key that is present
# but null clearing the vault value.
#
# It differs in one way. The generic resolver JSON-decodes each OCFP vault
# value, which turns a password of null into nothing, "quoted" into quoted,
# true into 1, 1e3 into 1000, and [1] into an array. A PVE credential is an
# opaque string, so the vault value is used exactly as stored.
sub _resolve_pve_credential {
	my ($self, $spec, $routed) = @_;
	for my $name (defined($routed) ? ($routed) : @{$spec->{lookups}}) {
		my ($value, $found) = $self->_lookup_operator_value($name);
		next unless $found;
		return $self->_pve_credential($spec, $value, "bosh-configs.cpi.$name", 0);
	}
	for my $name (@{$spec->{lookups}}) {
		my ($raw, $found) = $self->env->ocfp_config_lookup("cpi.pve.$name", undef);
		next unless $found;
		return $self->_pve_credential($spec, $raw, $self->_pve_vault_path.":$name", 1);
	}
	return (undef, 0);
}

# }}}
# _pve_credential - Judge one resolved PVE credential before entombment {{{
#
# Returns the (value, found) pair the generic gather expects, or bails.
#
# - An undefined or empty value means the credential is not in use, so the
#   optional entry is skipped. ocfp-cli used to write an empty placeholder for
#   the inactive credential, and some vaults still hold one.
#
# - A non-scalar can only come from the env file, where YAML parsed an
#   unquoted value such as true, or a hash or a list. Its string form is not
#   the operator's credential, so the operator has to quote it.
#
# - The string 0 is refused. Genesis can entomb it, but its write into the
#   director's own CredHub rejects any false value, so it would fail at
#   post-deploy, after the director had been deployed.
#
# - A vault value shaped like ((...)) is refused. Genesis passes any complete
#   ((...)) through as a reference to a value already in CredHub, before it
#   looks at the secret flag, so a password such as ((opaque-password)) would
#   reach the director as the name of a CredHub entry, and nothing would be
#   entombed. In vault that shape is almost certainly a mistake. In the env
#   file it is the documented way to point at a CredHub value, so it is kept.
sub _pve_credential {
	my ($self, $spec, $value, $source, $from_vault) = @_;

	return (undef, 1) if !defined($value) || (!ref($value) && $value eq '');

	bail(
		"#C{%s} is %s, but a PVE credential must be a string.  YAML reads an ".
		"unquoted value such as #C{true}, #C{1.0} or #C{[...]} as something else, ".
		"so quote the value in the environment file.",
		$source, ref($value) eq 'HASH' ? 'a map' : ref($value) eq 'ARRAY' ? 'a list' : 'a YAML boolean or other non-string'
	) if ref($value);

	bail(
		"The PVE credential from #C{%s} is the string \"0\", which Genesis cannot ".
		"store in the director's CredHub, because it refuses any secret whose ".
		"value is false.  Use a different credential.",
		$source
	) if $value eq '0';

	bail(
		"The PVE credential at #C{%s} is shaped like a BOSH reference.  A cpi ".
		"config would pass it through as the name of a CredHub entry instead of ".
		"storing the credential.  Store the credential itself in vault, or put ".
		"the reference in the environment file's #C{bosh-configs.cpi} instead.",
		$source
	) if $from_vault && $value =~ /^\(\(.*\)\)$/;

	$self->{pve_credential_source}{$spec->{key}} = $source;
	return ($value, 1);
}

# }}}
# _pve_vault_path - The vault secret the OCFP PVE config is read from {{{
sub _pve_vault_path {
	my ($self) = @_;
	return $self->env->ocfp_config_base.'/cpi/pve';
}

# }}}

# Generate CPI configuration based on IaaS type
sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	# There is no CPI config if the environment is not using OCFP
	$self->done() unless ($self->env->is_ocfp);

	# Check if CPI config generation is disabled
	my $cpi_enabled = $self->env->lookup('params.bosh-configs.cpi.enabled')//1; # Default to enabled
	unless ($cpi_enabled) {
		info("CPI config generation is disabled via #m{bosh-configs.cpi.enabled} = #B{false}");
		# We might still need to have shadow networking azs (see cloud-config.pm)
		return $self->done();
	}

	# The CPI config should be based on what type of IaaS we're using
	# The gather_properties methods will bail on error so no need to error check
	my $config = $self->build_cpi_config_for_iaas(
		'openstack' => sub { $self->gather_properties($self->_property_map_for_openstack) },
		'stackit'   => sub { $self->gather_properties($self->_property_map_for_stackit) },
		'vsphere'   => sub { $self->gather_properties($self->_property_map_for_vsphere) },
		'gcp'       => sub { $self->gather_properties(qw/project !json_key/) },
		'aws'       => sub { $self->gather_properties($self->_property_map_for_aws) },
		'pve'       => sub { $self->gather_properties_for_pve },
	);
	$config->{cpis}[0]{type} = 'google' if $self->iaas eq 'gcp';
	$self->done($config);
}


# IaaS-specific CPI configs {{{

# OpenStack CPI configuration properties
sub _property_map_for_openstack {
	qw/
		!project
		!project_id
		project_domain_name@domain
		region:RegionOne
		user_domain_name@domain
		!auth_url
		username
		!api_key@password
		boot_from_volume:true
		connection_read_timeout:1500>connection_options.read_timeout
		default_key_name:ocfp
		default_security_groups:["bosh"]
		default_volume_type:storage_premium_perf2
		human_readable_vm_names:true
		root_disk_size:30>root_disk.size
		state_timeout:600
		use_dhcp:true
	/;
}

# Stackit CPI configuration - extends OpenStack with Stackit-specific properties
sub _property_map_for_stackit {
	my ($self) = @_;

	return qw/
		!project_id
		org_id
		!service_account_json
		region:eu01
		auth_url
		endpoint
		boot_from_volume:true
		connection_read_timeout:1500>connection_options.read_timeout
		default_key_name@keypair_name:ocfp
		default_security_groups:["default"]
		default_root_volume_type:storage_premium_perf2
		default_persistent_volume_type:storage_premium_perf6
		human_readable_vm_names:true
		root_disk_size:30>root_disk.size
		state_timeout:600
		use_dhcp:true
	/;
}

# vSphere CPI configuration properties
sub _property_map_for_vsphere {
	qw/
		!vcenter_address@host
		!user
		!password
		datacenters
		datacenter@datacenters.first.name
		clusters@datacenters.first.clusters
		resource_pool@datacenters.first.resource_pool
		ephemeral_datastores@datacenters.first.datastore_pattern
		persistent_datastores@datacenters.first.persistent_datastore_pattern
		folder@datacenters.first.vm_folder
		template_folder@datacenters.first.template_folder
		disk_path@datacenters.first.disk_path
		enable_auto_anti_affinity_drs_rules:true@datacenters.first.enable_auto_anti_affinity_drs_rules
		nsxt@nsxt
	/;
}

# AWS CPI configuration properties
sub _property_map_for_aws {
	qw/
		!access_key_id
		!secret_access_key
		!region
		default_key_name@keypair_name:ocfp
		default_security_groups:["bosh"]
		ec2_endpoint?
		max_retries:10
		encrypted:true
		kms_key_arn?
		iam_instance_profile?
		http_endpoint:enabled>metadata_options.http_endpoint
		http_tokens:required>metadata_options.http_tokens
		http_put_response_hop_limit?>metadata_options.http_put_response_hop_limit
	/;
}

# PVE CPI configuration properties
# Maps bosh-configs.cpi.* keys to PVE CPI job properties.
# All keys are sourced from bosh-configs.cpi (OCFP convention), with the
# unprefixed spec name (@alt) as the alternate lookup for OCFP config values.
# Secret fields (!) are entombed, which means the hook stores the value in
# CredHub and the config carries only a ((reference)) to it.  `!` has meant "secret"
# since Genesis first shipped cpi configs; it does not mean "required".
# Optional fields (?) are omitted when absent.
# Default values (:value) are used when the key is absent.
# A field with neither a default nor `?` is required, and the hook bails
# when no value is found for it.
#
# pve_password and pve_api_token are optional secrets with no default, so
# whichever one the bloc uses is entombed and the other is left out.  An
# empty default would make every token-mode environment try to entomb an
# empty password, which Genesis refuses.  gather_properties_for_pve checks
# that exactly one of them is set.
#
# Every entry carries an explicit >path because the OCFP lookup key and the
# job property are not the same name: jobs/pve_cpi/spec declares these under
# the `pve.` namespace (pve.host, pve.node, ...) plus the shared `agent.mbus`,
# while the env yml keys them flat as pve_host, pve_node, ... Without >path
# the emitted property name defaults to the lookup key, so the whole block
# landed at the top level where jobs/pve_cpi/templates/cpi.json.erb -- which
# reads p("pve.host"), p("pve.node"), if_p("agent.mbus") -- never saw it.
sub _property_map_for_pve {
	qw/
		!pve_host@host>pve.host
		pve_port@port:8006>pve.port
		!pve_user@user>pve.user
		pve_realm@realm:pam>pve.realm
		!pve_password@password?>pve.password
		!pve_api_token@api_token?>pve.api_token
		!pve_node@node>pve.node
		pve_vm_storage@vm_storage:local-lvm>pve.vm_storage
		pve_disk_storage@disk_storage:local-lvm>pve.disk_storage
		pve_stemcell_storage@stemcell_storage:local>pve.stemcell_storage
		pve_iso_storage@iso_storage:local>pve.iso_storage
		pve_network_bridge@network_bridge:vmbr0>pve.network_bridge
		pve_verify_ssl@verify_ssl:true>pve.verify_ssl
		pve_vmid_range_start@vmid_range_start:200>pve.vmid_range_start
		pve_agent_mode@agent_mode:cloudinit>pve.agent_mode
		pve_vm_disk_format@vm_disk_format:raw>pve.vm_disk_format
		pve_parker_prefix@parker_prefix:bosh>pve.parker_prefix
		pve_agent_mbus@agent.mbus:"">agent.mbus
	/;
}

# gather_properties, then drop the source keys the pve map already consumed.
#
# gather_properties keys its working hash by the *output path*, but its
# trailing manual-override pass -- the one that lets an environment set CPI
# properties the kit does not model -- keys off the bosh-configs.cpi *source
# key*. While path and key were identical those two agreed. Every entry in
# the pve map now sets an explicit >path, so each source key the operator
# actually set in their env yml fails that pass's `exists $config{$override}`
# guard and is copied back in verbatim at the top level, beside the correctly
# nested value.
#
# The duplicate is not cosmetic, because the override pass copies the value
# neither entombed nor evaluated:
#
#   - `!` secrets are re-emitted in cleartext. pve_host, pve_user and pve_node
#     resolve to a ((/cpi-config/properties/...)) credhub reference under
#     pve.*, and then the raw value reappears as top-level pve_host, pve_user,
#     pve_node. That defeats the entombment the `!` exists to perform.
#
#   - a spruce operator is copied as a literal and reaches the director as a
#     BOSH variable reference, which fails every deployment against that
#     director until the operator rewrites it as a literal:
#       Variable name ' concat "nats://" params.static_ip ":4222" ' must only
#       contain alphanumeric, underscores, dashes, or forward slash characters
#
# Only keys this map itself consumed are removed -- its lookup key and any
# @alternates, and only when they resolved to a different output path. Genuine
# passthrough of keys the kit does not model is untouched, which is what the
# override pass is for.
sub gather_properties_for_pve {
	my ($self) = @_;

	$self->_require_pve_credential_routing;
	$self->{pve_credential_source} = {};

	my @map = $self->_property_map_for_pve;
	my $properties = $self->gather_properties(@map);

	for my $property (@map) {
		# Same parse as Genesis::Hook::CpiConfig::gather_properties:
		#   [!]property_name[@alternate_lookup][:default_value|?][>config_path]
		my (undef, $key, $alts, undef, undef, $path) =
			$property =~ /^(!?)([^\@:\?\>]+)(?:\@([^:\?\>]+))?(?:(?::([^>]+))|(\?))?(?:>(.+))?$/;

		# No >path means the output name already is the source key: the value
		# sitting at that key is the mapped value, not a duplicate of it.
		next unless defined $path;

		for my $source ($key, split(/,/, $alts // '')) {
			next if $source eq $path;
			delete $properties->{$source};
		}
	}

	$self->_drop_pve_kit_consumed_keys($properties);
	$self->_apply_pve_agent_mbus($properties);
	$self->_drop_pve_placement_authority_from_child($properties);
	$self->_select_one_pve_credential($properties);
	$self->_refuse_plaintext_pve_credentials($properties);

	return $properties;
}
# }}}
# _require_pve_credential_routing - Refuse a Genesis without destination-aware lookups {{{
#
# The PVE credential resolver reads the operator's value through
# _lookup_operator_value, which picks lookup_entombed_self for the director's
# own config and lookup_entombed for the parent copy, based on the
# self_upload flag Genesis passes for the own-director upload.  Without that
# routing, a credential would be entombed into one director's CredHub and
# referenced from a config the other director resolves.
#
# Those arrived together in Genesis 26377daa, which no tagged release carries
# yet, so check_minimum_genesis_version cannot express the requirement.  The
# self_upload flag cannot be probed, but it shipped in the same commit as
# _lookup_operator_value, which stands in for it.  An earlier build that has
# _resolve but none of the rest, such as 8f8a5612, is refused too.
sub _require_pve_credential_routing {
	my ($self) = @_;
	my @missing = map { $_->[0] } grep { !$_->[1] } (
		['Genesis::Hook::CpiConfig::_resolve',               Genesis::Hook::CpiConfig->can('_resolve')],
		['Genesis::Hook::CpiConfig::_lookup_operator_value', Genesis::Hook::CpiConfig->can('_lookup_operator_value')],
		['Genesis::Env::lookup_entombed',                    $self->env->can('lookup_entombed')],
		['Genesis::Env::lookup_entombed_self',               $self->env->can('lookup_entombed_self')],
	);
	bail(
		"The PVE cpi config needs a Genesis build that entombs CPI values for ".
		"the director using them (Genesis commit 26377daa, newer than ".
		"v3.2.0-rc.24).  This Genesis lacks %s.  Upgrade Genesis and try again.",
		join(', ', map { "#C{$_}" } @missing)
	) if @missing;
	return;
}

# }}}
# _select_one_pve_credential - Exactly one of pve.api_token and pve.password {{{
#
# The CPI lets a token win when both are present, but a bloc that moved from
# token to password mode can still hold its old token in vault, because ocfp
# vault populate merges keys into the existing secret.  The director job
# would then use the password while the cpi config used the stale token,
# which works until that token is revoked.  So two credentials are refused,
# naming where each came from, and nothing is uploaded.
#
# No credential at all is refused too.  CPI 0.9.4 and later would fail every
# call made through the config, and an older CPI would quietly use its own
# job's credential, which on a parent director is the parent's.
#
# This runs before the hook returns, so Genesis has neither a config to
# upload nor the hook's secrets to commit.
sub _select_one_pve_credential {
	my ($self, $properties) = @_;
	my $pve = ref($properties->{pve}) eq 'HASH' ? $properties->{pve} : {};
	my %present = map { ($_ => 1) } grep {
		defined($pve->{$_}) && (ref($pve->{$_}) || $pve->{$_} ne '')
	} qw(api_token password);

	my $source = sub {
		my ($key) = @_;
		return $self->{pve_credential_source}{$key}
			// 'a block in #C{bosh-configs.cpi} that the kit passes through';
	};

	bail(
		"Both PVE credentials are set, and the kit will not choose between them.  ".
		"#C{pve.api_token} comes from #C{%s} and #C{pve.password} comes from #C{%s}.  ".
		"Clear the one this bloc does not use, either by setting it to null in the ".
		"environment file (for example #C{bosh-configs.cpi.pve_password: ~}) or by ".
		"deleting the stale key from #C{%s}.",
		$source->('pve_api_token'), $source->('pve_password'), $self->_pve_vault_path
	) if $present{api_token} && $present{password};

	bail(
		"No PVE credential was found for the cpi config, because neither ".
		"#C{pve.api_token} nor #C{pve.password} has a value.  Set #C{api_token} or #C{password} in ".
		"#C{%s}, or #C{pve_api_token} or #C{pve_password} in the environment ".
		"file's #C{bosh-configs.cpi}.",
		$self->_pve_vault_path
	) unless $present{api_token} || $present{password};

	return;
}

# }}}
# _refuse_plaintext_pve_credentials - The returned config carries credentials only as references {{{
#
# The resolver entombs the two credentials it resolves, but some routes never
# reach it.  A block given as an expression, such as
#   bosh-configs.cpi.pve: (( grab params.pve_props ))
# is one leaf whose name matches no map entry, so gather_properties copies its
# evaluated value in as an extra property, entombing nothing.  So the last
# step is to check the whole returned tree against the path-aware rule in
# pve_credential_violations, and bail naming every node that breaks it.
sub _refuse_plaintext_pve_credentials {
	my ($self, $properties) = @_;
	my @bad = pve_credential_violations($properties);
	bail(
		"The PVE cpi config would carry a credential in plaintext:\n%s\n".
		"Set each of these through #C{(( vault \"...\" ))} or a #C{((/path))} ".
		"CredHub reference instead of a literal value.",
		join("\n", map { "[[  - >>#C{$_->{path}} $_->{reason}" } @bad)
	) if @bad;
	return;
}

# }}}
# pve_credential_paths - The cpi config paths the PVE CPI reads a credential from {{{
#
# The CPI reads a cpi config only through its context-override setters, and
# only two of them set a credential: pve_password and pve_api_token.  It
# folds the nested pve map into the same flat names, pve.<key> becoming
# pve_<key>, so each credential has a flat and a nested path.
#
# pve.lb_register.password is not read from a cpi config, but the job spec
# declares it a credential, and an operator copying job properties into a
# cpi config would put a real password there.
#
# spec/unit/fixtures/pve_cpi-credential-setters.txt lists the CPI's credential
# setters, and the unit test fails if this list stops covering them.
sub pve_credential_paths {
	return qw(pve_password pve_api_token pve.password pve.api_token pve.lb_register.password);
}

# }}}
# pve_credential_nodes - The nodes of a PVE cpi config's properties that the credential rule judges {{{
#
# Returns [path, node, kind] for each node, where kind is
#
#   credential - the node sits at a credential path, or at a property-name
#                position under a name that looks like a credential.  It is
#                not descended into, so a hash or a list there is judged as a
#                whole whatever its children are called.
#   string     - any other plain string, at any depth, for the URL rule.
#
# The rule has to tell a property name, which the CPI defines, from a key the
# operator chose inside a property's value.  pve_storage_sets,
# pve_storage_capacity_domains, pve_vm_types and pve_disk_types all take maps
# keyed by names the operator picks, and a storage set called secret is
# legal.  So the name pattern applies only at property-name positions: the
# top-level keys, the keys directly under pve and agent, and the keys directly
# under pve.lb_register.  Below those, keys are operator-chosen or part of a
# fixed sub-schema with no credential in it.
#
# A key that is the empty string is the whole bosh-configs.cpi block, which
# gather_properties copies in under that name when the block is given as one
# expression.  Its children are judged as if they were at the top level,
# because that is what they were written as.
my $PVE_CREDENTIAL_NAME = qr/^(?:.*_)?(?:password|api_token|token_secret|secret)$/;

sub pve_credential_nodes {
	my ($node, @path) = @_;
	my %credential_path = map { ($_ => 1) } pve_credential_paths();
	my @nodes;
	my $walk;
	$walk = sub {
		my ($node, @path) = @_;
		my $dotted = join('.', @path) =~ s/\.\[/[/gr;
		if (@path) {
			my $parent = join('.', @path[0 .. $#path - 1]);
			my $name_position = @path == 1
				|| (@path == 2 && ($parent eq 'pve' || $parent eq 'agent'))
				|| (@path == 3 && $parent eq 'pve.lb_register');
			if ($credential_path{$dotted} || ($name_position && $path[-1] =~ $PVE_CREDENTIAL_NAME)) {
				push @nodes, [$dotted, $node, 'credential'];
				return;
			}
		}
		if (ref($node) eq 'HASH') {
			for my $key (sort keys %$node) {
				$walk->($node->{$key}, (!@path && $key eq '') ? () : (@path, $key));
			}
		} elsif (ref($node) eq 'ARRAY') {
			$walk->($node->[$_], @path, "[$_]") for 0 .. $#$node;
		} elsif (defined($node) && !ref($node)) {
			push @nodes, [$dotted, $node, 'string'];
		}
	};
	$walk->($node, @path);
	undef $walk;
	return @nodes;
}

# }}}
# pve_credential_violations - Nodes of a PVE cpi config that carry a credential other than by reference {{{
#
# Every credential node must be a single scalar, complete ((name)) BOSH
# variable reference, and every URL with a password in it, such as
#   nats://user:secret@10.0.0.4:4222
# must use a reference for that password.  With absolute => 1, as the inline
# director-cpi upload needs, each reference must also be absolute, ((/...)).
#
# A reference name holds no whitespace or parentheses, so a Spruce operator
# such as (( grab params.x )) is not one.
#
# Returns {path, reason} for each node that breaks the rule.
sub pve_credential_violations {
	my ($properties, %opts) = @_;
	my $reference = $opts{absolute} ? qr/^\(\(\/[^()\s]+\)\)$/ : qr/^\(\([^()\s]+\)\)$/;
	my @bad;
	for my $item (pve_credential_nodes($properties)) {
		my ($path, $node, $kind) = @$item;
		if ($kind eq 'credential') {
			next if defined($node) && !ref($node) && $node =~ $reference;
			push @bad, {
				path   => $path,
				reason => $opts{absolute}
					? 'is not an absolute ((/...)) CredHub reference'
					: 'is not a ((...)) CredHub reference',
			};
		} else {
			while ($node =~ m{[A-Za-z][A-Za-z0-9+.\-]*://((?:\(\([^()]*\)\)|[^/?#@\s])*)@}g) {
				my $userinfo = $1;
				my ($password) = $userinfo =~ /^(?:\(\([^()]*\)\)|[^:])*:(.*)$/s;
				next if !defined($password) || $password eq '' || $password =~ $reference;
				push @bad, { path => $path, reason => 'carries a URL password that is not a CredHub reference' };
				last;
			}
		}
	}
	return @bad;
}

# }}}
# _drop_pve_kit_consumed_keys - Keep keys the kit consumes itself out of the CPI context {{{
#
# Some bosh-configs.cpi keys are inputs to the kit, not to the CPI job. The
# override pass in gather_properties copies every key the pve map does not
# model straight through as a top-level context override, so these reached
# the cpi config beside pve:. CPI 0.9.4 and later check every context key
# against the pve_cpi job spec and reject the ones it does not define, which
# fails create_stemcell with "context override rejected".
#
#   pve_host_operator  - the create-env host, read by overlay/cpis/pve-proto.yml
#                        and ocfp/pve/base.yml. The director's CPI uses pve.host.
#   pve_disk_format    - the disk_types disk_format cloud property, read by
#                        hooks/cloud-config.pm. The CPI-wide default is
#                        pve.vm_disk_format, mapped from pve_vm_disk_format.
#   pve_bosh_*         - the director VM's sizing, read by hooks/cloud-config.pm.
#   pve_compilation_*  - the compilation VMs' sizing, read by
#                        hooks/cloud-config-director.pm.
#
# Both the flat key and a nested pve.* form are removed, because the CPI folds
# the nested form into the same flat override key. The kit reads only the flat
# key, so a nested form is reported as ignored.
sub _drop_pve_kit_consumed_keys {
	my ($self, $properties) = @_;

	for my $key (qw/
		host_operator disk_format
		bosh_cpu bosh_ram bosh_disk
		compilation_cpu compilation_ram compilation_disk
	/) {
		delete $properties->{"pve_$key"};
		next unless ref($properties->{pve}) eq 'HASH' && exists $properties->{pve}{$key};
		delete $properties->{pve}{$key};
		warning(
			"Ignoring #C{bosh-configs.cpi.pve.%s}, because the kit reads only the ".
			"flat #C{bosh-configs.cpi.pve_%s} key.  Set that key instead.", $key, $key
		);
	}
	return;
}
# }}}
# _apply_pve_agent_mbus - Default agent.mbus to the NATS of the director that owns the agent {{{
#
# A NATS-mTLS director hands the CPI env.bosh.mbus.cert but no URL, so the URL
# has to come from the CPI's own agent.mbus property. Leaving it empty fails
# every create_vm with "registry-less agent requires non-empty mbus".
#
# The right URL depends on which of the two cpi configs this hook is building,
# and the two do not name the same director:
#
#   own-director config - the config uploaded to the director THIS environment
#     deploys. That director manages its own deployments, so their agents
#     report to this environment's own NATS, reachable at params.static_ip.
#
#   child config - the config handed to the PARENT director, which uses it to
#     build this environment's director VM. That VM's agent reports to the
#     parent, whose address comes from the parent's exodus data.
#
# Genesis tells the two apart by the credhub_prefix it passes: the own-director
# call takes Genesis' default DIRECTOR_CREDHUB_PREFIX, because those references
# have to resolve against the new director's own Credhub, while the child call
# passes the environment's cpi_credhub_base, which always ends in
# genesis-entombed/ so the parent can resolve them. A create-env environment
# only ever produces the own-director config, so its lack of a parent to look
# up is never reached.
#
# An explicit bosh-configs.cpi.pve_agent_mbus always wins: this only fills in
# the default the property map leaves empty.
sub _apply_pve_agent_mbus {
	my ($self, $properties) = @_;

	return if (($properties->{agent}{mbus} // '') ne '');

	my $prefix = $self->{credhub_prefix} // DIRECTOR_CREDHUB_PREFIX;
	my ($ip, $missing);
	if ($prefix eq DIRECTOR_CREDHUB_PREFIX) {
		$ip = $self->env->lookup('params.static_ip');
		$missing = "this environment declares no params.static_ip";
	} else {
		my $url = $self->env->director_exodus_lookup('url');
		($ip) = ($url // '') =~ m{^\w+://\[?([^\]/:]+)\]?};
		$missing = "the parent director's exodus data carries no usable url";
	}

	bail(
		"Cannot determine the NATS address for the PVE CPI's agent.mbus: %s. ".
		"Set bosh-configs.cpi.pve_agent_mbus explicitly.", $missing
	) unless defined($ip) && $ip ne '';

	$properties->{agent}{mbus} = "nats://$ip:4222";
	return;
}
# }}}
# _drop_pve_placement_authority_from_child - Keep the parent's journal authority over the child director's VM {{{
#
# pve_storage_placement_namespace and pve_storage_allocation_journal_dir name
# the placement authority this environment's director enrolls in its own
# allocation journal. They belong on the own-director config, and the override
# pass in gather_properties copies them through untouched because the pve map
# does not model them. That is right for the own-director config and wrong for
# the child config, so they are taken back out of the child config here.
#
# The child config runs on the PARENT director's CPI, which builds this
# environment's director VM and records that allocation in the parent's own
# journal. The parent's journal only has the parent's namespace enrolled. The
# CPI accepts pve_storage_placement_namespace as a per-request override, so a
# child namespace switches the parent's CPI onto an authority its journal has
# never seen. create_vm then fails with
#   statat <sha256(child namespace)>: no such file or directory
# The child director's VM is the parent's allocation, so the parent's own
# namespace has to govern it.
#
# The journal directory is never a per-request override. It is process-level
# policy, set once where the CPI job runs and mounted into the director's BPM
# workers there. A path handed over from the child names a directory on this
# environment's director, which the parent's CPI cannot see, so it has no
# meaning on the parent and is dropped along with the namespace.
#
# Both the flat pve_* keys and a nested pve.* form are removed, because the
# CPI folds the nested form into the same flat override key. The storage-set
# keys (pve_storage_sets, pve_ephemeral_storage_set, ...) still pass through,
# because they name the pools the VM lands on and not whose journal records it.
sub _drop_pve_placement_authority_from_child {
	my ($self, $properties) = @_;

	my $prefix = $self->{credhub_prefix} // DIRECTOR_CREDHUB_PREFIX;
	return if $prefix eq DIRECTOR_CREDHUB_PREFIX;

	for my $key (qw/storage_placement_namespace storage_allocation_journal_dir/) {
		delete $properties->{"pve_$key"};
		delete $properties->{pve}{$key} if ref($properties->{pve}) eq 'HASH';
	}
	return;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
