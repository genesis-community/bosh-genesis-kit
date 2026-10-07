package Genesis::Hook::Check::BOSH v4.1.0;

use v5.20; # Genesis supports min perl v5.20.
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

# Parent class inheritance
use parent qw(Genesis::Hook::Check);

# Import required functions
use Genesis qw/bail info warning error in_array new_enough/;

# init - Initialize the hook and check minimum Genesis version {{{
sub init {
	my ($class, %ops) = @_;
	my $obj = $class->SUPER::init(%ops);
	$obj->check_minimum_genesis_version('3.1.0-rc.24');
	return $obj;
}

# }}}

# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;
	my $ok = 1;

	# Version compatibility checks
	$ok = 0 unless $self->check_version_compatibility();

	# Cloud Config checks
	$ok = 0 unless $self->check_cloud_config();

	# Environment Parameter checks
	$ok = 0 unless $self->check_environment_parameters();

	# OpenBao seal mode and seal key checks
	$ok = 0 unless $self->check_openbao_seal();

	return $self->done($ok);
}

# }}}

# check_cloud_config - Validate cloud config requirements {{{
sub check_cloud_config {
	my ($self) = @_;

	$self->start_check('cloud-config');

	return $self->check_result('cloud-config', 'skipped', "not applicable to create env environments") if $self->use_create_env;
	return $self->check_result('cloud-config', 'skipped', "OCFP env manages its own cloud-config") if $self->is_ocfp;
	return $self->check_result('cloud-config', 'failed', "no cloud config found") unless $self->env->has_config('cloud');

	my ($vm_type, $network, $disk_type);
	my $env = $self->env;

	# Legacy was hard coded
	$vm_type = "large";
	$network = "bosh";
	$disk_type = "bosh";

	$self->has_entry('cloud-config','vm_type', $vm_type);
	$self->has_entry('cloud-config','network', $network);
	$self->has_entry('cloud-config','disk_type', $disk_type);
	return $self->check_result('cloud-config');
}

# }}}

# check_environment_parameters - Validate environment-specific parameters {{{
sub check_environment_parameters {
	my ($self) = @_;

	# Check trust-parent-bosh feature requirements
	if ($self->env->has_feature('trust-parent-bosh') && !$self->env->has_feature('ocfp')) {
		$self->start_check('trust-parent-bosh');
		my $parent_env = $self->env->lookup('genesis.bosh_env');
		unless ($parent_env) {
			return $self->check_result(
				'trust-parent-bosh',
				'failed',
				"The trust-parent-bosh feature requires 'genesis.bosh_env' to be set"
			);
		}

		# Check if parent exodus data exists
		my $parent_ca = $self->env->exodus_lookup("$parent_env/bosh", "ca_cert");
		unless ($parent_ca) {
			return $self->check_result(
				'trust-parent-bosh',
				'warning',
				"Cannot find parent BOSH CA certificate in exodus/$parent_env/bosh:ca_cert"
			);
		}
		$self->check_result('trust-parent-bosh');
	}

	if ($self->iaas eq 'vsphere') {
		$self->start_check('environment');
		for my $ds_type (qw(ephemeral persistent)) {
			my $param_name = "vsphere_${ds_type}_datastores";
			$self->has_entry('environment', 'params', $param_name, type => 'array', msg => 'is an array');
		}
		return $self->check_result('environment');
	} elsif ($self->iaas eq 'aws') {
		$self->start_check('environment');

		# Check for outdated parameters.
		#
		# Only fires in OCFP mode (both hosted and create-env variants).
		# In non-OCFP create-env, these param names are actively load-
		# bearing via overlay/cpis/aws-proto.yml; in non-OCFP hosted,
		# there's no manifest-level `bosh-configs.cpi.*` target so the
		# migration message is misleading.  A longer-term unified-schema
		# design is tracked separately and will supersede this check.
		my $moved_params = $self->is_ocfp ? {
			ephemeral_disk_size => 'bosh-configs.cpi.ephemeral_disk_size_in_mb',
			persistent_disk_size => 'bosh-configs.cpi.persistent_disk_size_in_mb',
			aws_disk_type => 'bosh-configs.cpi.default_disk_type',
			aws_instance_type => 'bosh-configs.cpi.instance_type',
			aws_security_groups => 'params.security_groups',
		} : {};

		# Check for moved parameters
		my @found_moved_params = grep {
			$self->env->lookup("params.$_")
		} keys %$moved_params;

		if (@found_moved_params) {
			$self->start_check('environment');
			return $self->check_result(
				'environment',
				'failed',
				"the following parameters have moved:\n".
				join("\n", map { sprintf(
					"[[ - #R{params.%s}  => >>(now: #g{%s})",
					$_, $moved_params->{$_}
				)} @found_moved_params).
				"\nPlease update your environment configuration accordingly."
			);
		}	
		return $self->check_result('environment');
	} elsif ($self->iaas eq 'pve') {
		$self->start_check('environment');

		# The bosh-proxmox-cpi release entry used to be assembled from a local
		# dev tarball path (file://((pve_cpi_release_path))); it now takes a
		# complete URL and defaults to the published release. A leftover
		# pve_cpi_release_path no longer feeds any merge, so the env would
		# quietly deploy the default release instead of the named tarball.
		if ($self->env->lookup("params.pve_cpi_release_path")) {
			return $self->check_result(
				'environment',
				'failed',
				"the following parameters have moved:\n".
				"[[ - #R{params.pve_cpi_release_path}  => >>(now: #g{params.pve_cpi_release_url})\n".
				"The release entry now takes a complete URL: use a file:// URL for a ".
				"locally built tarball, or drop the parameter to deploy the kit's ".
				"default published bosh-proxmox-cpi release."
			);
		}
		return $self->check_result('environment');
	}
	return 1;
}

# }}}

# check_openbao_seal - Validate the OpenBao seal mode and seal keys {{{
#
# Only envs with the openbao feature are checked; every other env passes
# without a vault read.  An env that cannot be proven new must choose its
# seal mode explicitly, because the default for new envs (static) would
# start a seal migration on an initialized Shamir cluster.
#
# In static mode the check also guards the key itself.  genesis deploy
# fixes missing secrets before this check runs, so a key that vanished from
# the vault has already been replaced by a fresh random one by the time we
# look.  Two records catch that:
#   - exodus openbao_static_key_id, the id of the key a running static
#     server last unsealed with (written by the post-deploy hook); the
#     current key, or during a rotation the previous key, must derive to it;
#   - openbao/seal/escrow, written by the openbao-rotate-seal-key escrow
#     action after a verified copy; a deploy with no recorded key id (a
#     migration from Shamir, or a brand new server) needs one that matches
#     the current key, so the key exists outside the provider first.
# Seal key values are validated but never printed; key ids are not secret.
sub check_openbao_seal {
	my ($self) = @_;
	return 1 unless $self->want_feature('openbao');

	my $name = 'openbao seal';
	my $env = $self->env;
	my $helpers = $self->openbao_seal_helpers;
	my $state = $helpers->openbao_seal_state($env);
	$self->start_check($name);

	return $self->check_result($name, 'failed', sprintf(
		"#c{params.openbao_seal} must be #c{static} or #c{shamir}, not #C{%s}",
		ref($state->{param}) ? 'a '.lc(ref($state->{param})) : $state->{param} // ''
	)) unless $state->{valid};

	if (!defined($state->{param}) && ($state->{source} // '') eq 'existing-default') {
		return $self->check_result($name, 'failed', sprintf(
			"#c{params.openbao_seal} is not set, and %s, so the environment must ".
			"choose a seal mode explicitly.  Add #c{openbao_seal: shamir} under ".
			"#c{params} to keep a Shamir seal, or add #c{openbao_seal: static} ".
			"only after reading the static seal migration runbook in ".
			"#C{docs/openbao-operations.md}, because on an initialized Shamir ".
			"server that starts a seal migration.",
			$state->{reason} // 'the kit could not prove that it is new'
		));
	}

	# The exodus data records the mode this kit last rendered, so an env
	# deployed on the default keeps it; ask for the param, but go ahead.
	my $implicit = '';
	if (!defined($state->{param}) && ($state->{source} // '') =~ /^(exodus|new-default)$/) {
		$self->check_result($name, 'warning', sprintf(
			"#c{params.openbao_seal} is not set; using the #c{%s} seal %s.  Add ".
			"#c{openbao_seal: %s} under #c{params} to make it explicit, which also ".
			"stops the kit from reading the vault to decide on every command.",
			$state->{mode},
			$state->{source} eq 'exodus'
				? 'this environment was last deployed with'
				: 'that new environments default to',
			$state->{mode}
		));
		$self->start_check($name);
		$implicit = $state->{source} eq 'exodus'
			? ' (kept from the last deploy)' : ' (new environment default)';
	}

	my $disabled = $env->lookup('params.openbao_seal_static_disabled', undef);
	if ($state->{mode} eq 'shamir') {
		return $self->check_result($name, 'failed',
			"#c{params.openbao_seal_static_disabled} applies only to the static ".
			"seal; remove it, or set #c{openbao_seal: static} while migrating ".
			"back to Shamir"
		) if $disabled && $disabled ne 'false';
		return $self->check_result($name, 'passed', "shamir seal$implicit");
	}
	my $mode_label = "static seal$implicit";

	my $exodus   = $helpers->openbao_exodus($env);
	my $recorded = ref($exodus) eq 'HASH' ? $exodus->{openbao_static_key_id} : undef;
	$recorded = undef unless defined($recorded) && !ref($recorded) && $recorded ne '';

	# Static mode: the current key must be stored exactly as 64 lowercase
	# hex characters.  OpenBao does not trim the key file, so a stored value
	# with a trailing newline stops the server from starting.
	my $current = $helpers->openbao_vault_secret($env, 'openbao/seal/static');
	unless ($current && defined($current->{key})) {
		return $self->check_result($name, 'failed', sprintf(
			"the static seal key #C{openbao/seal/static:key} is not in the vault, but ".
			"the server last unsealed with key id #C{%s}.  Restore that key from the ".
			"escrow vault before deploying; a new key cannot unseal the existing data.",
			$recorded
		)) if $recorded;
		return $self->check_result($name, 'warning',
			"$mode_label; the seal key #C{openbao/seal/static:key} is not in the vault ".
			"yet.  Run #c{genesis add-secrets}, then escrow the key with ".
			"#c{genesis <env> do openbao-rotate-seal-key escrow --escrow-target <vault>} ".
			"before deploying."
		);
	}
	if (my $problem = $helpers->openbao_static_key_problem($current->{key})) {
		return $self->check_result($name, 'failed',
			"the static seal key #C{openbao/seal/static:key} is unusable because $problem"
		);
	}
	my $current_id = $helpers->openbao_static_key_id($current->{key});

	# A rotation in progress keeps the outgoing key and its id beside the
	# current key.  The release needs both, and the id must be the one the
	# server derived for that key when it was current.
	my $previous = $helpers->openbao_vault_secret($env, 'openbao/seal/static-previous');
	my $rotating = 0;
	if ($previous) {
		if (my $problem = $helpers->openbao_static_key_problem($previous->{key})) {
			return $self->check_result($name, 'failed',
				"the previous static seal key #C{openbao/seal/static-previous:key} is unusable because $problem"
			);
		}
		my $want = $helpers->openbao_static_key_id($previous->{key});
		return $self->check_result($name, 'failed',
			"#C{openbao/seal/static-previous:id} does not match the id derived from ".
			"the previous key; OpenBao could not find the data that key wrapped.  ".
			"Store the derived id with #c{genesis <env> do openbao-rotate-seal-key repair-id}"
		) unless defined($previous->{id}) && $previous->{id} eq $want;
		$rotating = $previous->{key} ne $current->{key};
	}

	if ($recorded) {
		# The server is already static: the key we are about to render must be
		# the one it runs on, or the outgoing key of a rotation must be.
		my $matches = $recorded eq $current_id
			|| ($rotating && $previous->{id} eq $recorded);
		return $self->check_result($name, 'failed', sprintf(
			"the static seal key in the vault derives to id #C{%s}, but the server ".
			"last unsealed with key id #C{%s}.  Deploying would replace the key ".
			"file the server needs, and its data could not be decrypted again.  The ".
			"vault's key was most likely generated fresh by a secrets fix, or ".
			"restored from the wrong escrow copy.  Restore the key with id #C{%s} ".
			"(write it with printf %%s, never echo), and run this check again.",
			$current_id, $recorded, $recorded
		)) unless $matches;
	} else {
		# No running static server is on record, so this deploy starts the
		# static seal: a migration from Shamir, or a new server.  The key must
		# exist outside the provider before anything is wrapped under it.
		my $escrow = $helpers->openbao_vault_secret($env, 'openbao/seal/escrow');
		return $self->check_result($name, 'failed', sprintf(
			"this deploy starts the static seal (a migration from Shamir, or a new ".
			"server), and %s.  Escrow the key first with ".
			"#c{genesis <env> do openbao-rotate-seal-key escrow --escrow-target <vault>}, ".
			"which copies it to a second vault, checks the copy by SHA-256, and ".
			"records the escrow.",
			$escrow
				? "the escrow record names key id #C{".($escrow->{id} // 'none')."}, not ".
				  "the current key's id #C{$current_id}"
				: "no verified escrow of the current key (id #C{$current_id}) is recorded"
		)) unless $escrow && ($escrow->{id} // '') eq $current_id;
	}

	return $self->check_result($name, 'warning',
		"the previous static seal key is the same as the current key, so the ".
		"rotation has not replaced the key yet"
	) if $previous && !$rotating;
	return $self->check_result($name, 'passed',
		"$mode_label, rotation in progress (previous key present)"
	) if $rotating;
	return $self->check_result($name, 'passed', sprintf(
		"%s, key id %s%s", $mode_label, $current_id,
		$recorded ? '' : ', escrow verified'
	));
}

# openbao_seal_helpers - the package holding the OpenBao seal helpers
sub openbao_seal_helpers {
	my ($self) = @_;
	my $pkg = 'Genesis::Hook::Features::BOSH';
	require( $self->env->kit->path('hooks/features.pm') )
		unless $pkg->can('openbao_seal_state');
	return $pkg;
}

# }}}

# check_version_compatibility - Validate kit version upgrade compatibility {{{
sub check_version_compatibility {
	my ($self) = @_;
	my $last_version = $self->exodus_data->{kit_version};
	if ($last_version) {
		if (!new_enough($last_version, "3.0.0")) {
			$self->start_check('version upgrade compatibility');
			if (!new_enough($last_version, "2.3.0")) {
				return $self->check_result(
					'version upgrade compatibility',
					'warning',
					"forcing incompatible upgrade due to FORCE_INCOMPATIBLE_UPGRADE being set",
				) if $self->env->exodus_lookup('FORCE_INCOMPATIBLE_UPGRADE', '');
				return $self->check_result(
					'version upgrade compatibility',
					'failed',
					"please upgrade to at least bosh kit 2.3.0 before upgrading to v3.x.x",
				);
			}
			return $self->check_result('version upgrade compatibility', 'passed');
		}
	}
	return 1;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
