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
# without a vault read.  An env that has deployed OpenBao before must choose
# its seal mode explicitly, because the default for new envs (static) would
# start a seal migration on an initialized Shamir cluster.  Seal key values
# are validated but never printed.
sub check_openbao_seal {
	my ($self) = @_;
	return 1 unless $self->want_feature('openbao');

	my $name = 'openbao seal';
	my $helpers = $self->openbao_seal_helpers;
	my $state = $helpers->openbao_seal_state($self->env);
	$self->start_check($name);

	return $self->check_result($name, 'failed', sprintf(
		"#c{params.openbao_seal} must be #c{static} or #c{shamir}, not #C{%s}",
		ref($state->{param}) ? 'a '.lc(ref($state->{param})) : $state->{param} // ''
	)) unless $state->{valid};

	if (!defined($state->{param}) && ($state->{source} // '') eq 'existing-default') {
		return $self->check_result($name, 'failed',
			"this environment has deployed OpenBao before, so it must choose a ".
			"seal mode explicitly.  Add #c{openbao_seal: shamir} under #c{params} ".
			"to keep the Shamir seal it runs today, or add #c{openbao_seal: static} ".
			"only after reading the static seal migration runbook in ".
			"#C{docs/openbao-operations.md}, because that starts a seal migration."
		);
	}

	# The exodus data records the mode this kit last rendered, so an env
	# deployed on the default keeps it; ask for the param, but go ahead.
	my $implicit = '';
	if (!defined($state->{param}) && ($state->{source} // '') eq 'exodus') {
		$self->check_result($name, 'warning', sprintf(
			"#c{params.openbao_seal} is not set; keeping the #c{%s} seal this ".
			"environment was last deployed with.  Add #c{openbao_seal: %s} under ".
			"#c{params} to make it explicit.", $state->{mode}, $state->{mode}
		));
		$self->start_check($name);
		$implicit = ' (kept from the last deploy)';
	}

	my $disabled = $self->env->lookup('params.openbao_seal_static_disabled', undef);
	if ($state->{mode} eq 'shamir') {
		return $self->check_result($name, 'failed',
			"#c{params.openbao_seal_static_disabled} applies only to the static ".
			"seal; remove it, or set #c{openbao_seal: static} while migrating ".
			"back to Shamir"
		) if defined($disabled);
		return $self->check_result($name, 'passed', "shamir seal$implicit");
	}

	# Static mode: the current key must be stored exactly as 64 lowercase
	# hex characters.  OpenBao does not trim the key file, so a stored value
	# with a trailing newline stops the server from starting.
	my $current = $helpers->openbao_vault_secret($self->env, 'openbao/seal/static');
	my $mode_label = defined($state->{param}) ? 'static seal'
		: $implicit ? "static seal$implicit" : 'static seal (new environment default)';
	unless ($current && defined($current->{key})) {
		return $self->check_result($name, 'warning',
			"$mode_label; the seal key #C{openbao/seal/static:key} is not in the vault yet, ".
			"and #c{genesis add-secrets} generates it"
		);
	}
	if (my $problem = $helpers->openbao_static_key_problem($current->{key})) {
		return $self->check_result($name, 'failed',
			"the static seal key #C{openbao/seal/static:key} is unusable because $problem"
		);
	}

	# A rotation in progress keeps the outgoing key and its id beside the
	# current key.  The release needs both, and the id must be the one the
	# server derived for that key when it was current.
	my $previous = $helpers->openbao_vault_secret($self->env, 'openbao/seal/static-previous');
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
			"Store the derived id with #c{genesis do openbao-rotate-seal-key -- repair-id}"
		) unless defined($previous->{id}) && $previous->{id} eq $want;
		return $self->check_result($name, 'warning',
			"the previous static seal key is the same as the current key, so the ".
			"rotation has not replaced the key yet"
		) if $previous->{key} eq $current->{key};
		return $self->check_result($name, 'passed',
			"$mode_label, rotation in progress (previous key present)"
		);
	}

	return $self->check_result($name, 'passed', $mode_label);
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
