package Genesis::Hook::PostDeploy::BOSH v4.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info error warning run load_yaml_file count_nouns/;

# init - Initialize the hook and check minimum Genesis version {{{
sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.4');
	return $obj;
}

# }}}

# deploy_successful - Check if deployment was successful {{{
sub deploy_successful {
	my $self = shift;
	return ($self->{rc} // 255) == 0;
}

# }}}

# _upload_dns_runtime_config - Generate and upload the bosh-dns runtime config {{{
# to the just-deployed director by invoking the runtime-config hook directly.
#
# The genesis lib base-class `upload_runtime_configs` is an intentional no-op
# stub ("TBD: placeholder").  Until the library implements it, this kit method
# routes around the stub by calling run_hook('runtime-config', ...) the same way
# `hooks/addon-runtime-config~rc.pm::perform` does, but non-interactively.
#
# The bosh-dns runtime config is idempotent: `bosh update-runtime-config --name
# dns` overwrites any pre-existing config of the same name, so re-deploying is
# safe.  Failures (e.g. director not yet reachable) emit a warning and allow the
# caller to fall back to `genesis do rc dns -y`.
sub _upload_dns_runtime_config {
	my ($self) = @_;

	my $env = $self->env;

	my $ok = eval {
		$env->run_hook(
			'runtime-config',
			env         => $env,
			args        => [dns => {}],
			dryrun      => 0,
			interactive => 0,
			remove      => 0,
			print       => 0,
		);
		1;
	};
	if (!$ok || $@) {
		my $err = $@ // 'unknown error';
		$err =~ s/\s+$//;
		warning(
			"Could not auto-upload bosh-dns runtime config (%s).\n".
			"Run manually: #C{genesis do rc dns -y}",
			$err
		);
		return 0;
	}
	return 1;
}

# }}}

# perform - Execute post-deployment tasks for BOSH environments {{{
sub perform {
	my ($self) = @_;
	if ($self->deploy_successful) {
		my $env = $self->env;

		# Update the BOSH CPI config
		$self->upload_director_cpi_config();

		# Update the director cloud config and network mappings
		$self->update_director_network_config();

		# Generate and upload the bosh-dns runtime config directly via the
		# runtime-config hook.  The base-class upload_runtime_configs() is a
		# no-op stub; this routes around it until the genesis lib implements it.
		$self->_upload_dns_runtime_config();

		# Upload releases referenced by those runtime configs (e.g. bosh-dns)
		$self->upload_runtime_config_releases();

		# Upload a stemcell if there aren't any
		$self->upload_stemcells();

		# Provide usage assistance (aka help)
		my $usage = '';
		my @usage_args = ();
		my $need_self = $self->env->use_create_env ? '' : ' --self';
		my $cmd_with_env = $self->env->get_call_path_with_env();
		$usage .= "\n".
			"For details about the deployment, run\n".
			"[[  >>#G{%s info}\n\n".
			"To run bosh command against this BOSH director, as an adminstrator, run\n".
			"[[  >>#G{%s bosh$need_self <cmd> <options>}\n\n".
			"You can upload stemcells (you'll need at least one) by running\n".
			"[[  >>#G{%s do upload-stemcells}\n\n".
			"This BOSH director provides a Credhub secrets store.\n\n".
			"You can run credhub commands directly through Genesis by running\n".
			"[[  >>#G{%s credhub$need_self <cmd> <options>}\n\n";
		@usage_args = ($cmd_with_env) x 4;

		if ($env->has_feature('vault-credhub-proxy')) {
			$usage .=
				"It also provides a vault-credhub-proxy server, which allows you to ".
				"access credhub via #C{safe}.  To login, run\n".
				"[[  >>#G{%s do vault-proxy-login}\n\n";
			push @usage_args, $cmd_with_env
		}
		info($usage, @usage_args);

		$self->_openbao_health_hint if $env->has_feature('openbao');
	}
	return $self->done(1);
}

# }}}

# _openbao_health_hint - Report colocated OpenBao state after a deploy {{{
# No auto-init and no auto-unseal here - unseal keys and the root token are
# operator custody, never stored on or supplied to the VM automatically.
sub _openbao_health_hint {
	my ($self) = @_;
	my $env = $self->env;

	my $ip = $env->lookup('params.static_ip') or return 0;
	my $port = $env->lookup('params.openbao_port', 8200);
	my $url = "https://$ip:$port";
	my $cmd_with_env = $env->get_call_path_with_env();

	my ($code) = run(
		{stderr => 0},
		'curl', '-sk', '-o', '/dev/null', '-w', '%{http_code}',
		'-m5', "$url/v1/sys/health"
	);
	$code //= '';

	if ($code eq '501') {
		info(
			"This director hosts a colocated OpenBao server at #C{%s}, which is ".
			"#Y{not yet initialized}.  To initialize it, run\n".
			"[[  >>#G{%s do openbao-init}\n\n".
			"[[#Yiu{Note:} >>the unseal keys and root token are printed exactly ".
			"once.  Capture rules: #C{umask 077}; log via #C{script(1)} to a ".
			"#C{0600} file - never a tmux pane, never /tmp.\n",
			$url, $cmd_with_env
		);
	} elsif ($code eq '503') {
		info(
			"The colocated OpenBao server at #C{%s} is #Y{sealed} (expected ".
			"after a VM restart or recreate).  To unseal it, run\n".
			"[[  >>#G{%s do openbao-unseal}\n",
			$url, $cmd_with_env
		);
	} elsif ($code eq '200') {
		info(
			"The colocated OpenBao server at #C{%s} is #G{initialized and ".
			"unsealed}.  Check it anytime with #G{%s do openbao-status}.\n",
			$url, $cmd_with_env
		);
	} elsif ($code =~ /^(429|473)$/) {
		# This deployment colocates a single OpenBao node, so standby is
		# never a healthy state: it means the node cannot elect itself
		# leader (reads work, writes fail).  Seen in the wild after a
		# create-env recreate of a pre-0.3.1 deployment changed the BOSH
		# instance id out from under the persisted raft configuration.
		warning(
			"The colocated OpenBao server at %s is unsealed but reports ".
			"#Y{standby} (health returned '%s').  On this single-node ".
			"deployment that means it cannot become leader - reads work ".
			"but #R{writes will fail}.  Check with #C{%s do openbao-status}, ".
			"and see 'Raft Recovery After create-env Recreate' in the kit's ".
			"docs/openbao-operations.md for the peers.json recovery.",
			$url, $code, $cmd_with_env
		);
	} else {
		warning(
			"Could not reach the colocated OpenBao server at %s ".
			"(health returned '%s').  Check the #c{openbao} job on the ".
			"director, then run #C{%s do openbao-status}.",
			$url, $code, $cmd_with_env
		);
	}
	return 1;
}

# }}}

# upload_runtime_config_releases - Upload releases referenced by the kit's {{{
# runtime configs (notably bosh-dns) to the director.
#
# Genesis uploads the runtime CONFIG (`bosh update-runtime-config`) but NOT the
# releases that config references. Without the release present, the first deploy
# of any workload the bosh-dns addon applies to fails at task creation with
# "Release 'bosh-dns' doesn't exist". The dns runtime config sources its release
# pin (name/version/url/sha1) from bosh-deployment/runtime-configs/dns.yml, so we
# upload exactly that pin here. `bosh upload-release` is idempotent, so re-runs
# are safe.
sub upload_runtime_config_releases {
	my ($self) = @_;
	return unless $self->deploy_successful;

	my $env = $self->env;

	# The bosh-dns runtime config is always uploaded by _upload_dns_runtime_config,
	# so we always need the release present.  The legacy env-file guard
	# `bosh-configs.runtime.dns: true` is no longer needed for this path; we keep
	# the lookup only to honour explicit opt-out: if the key is explicitly set to
	# boolean false, skip the upload.
	my $runtime_opts = $env->lookup('bosh-configs.runtime', undef);
	if (ref($runtime_opts) eq 'HASH' && exists $runtime_opts->{dns}) {
		return unless $runtime_opts->{dns};
	}

	my $dns_yml = $env->kit->path('bosh-deployment/runtime-configs/dns.yml');
	return unless -f $dns_yml;

	my $data = load_yaml_file($dns_yml);
	my $releases = (ref($data) eq 'HASH' && ref($data->{releases}) eq 'ARRAY')
		? $data->{releases} : [];
	return unless @$releases;

	my $bosh = $env->get_target_bosh({self => 1});
	$env->notify("uploading runtime-config releases to the BOSH director");

	for my $rel (@$releases) {
		next unless $rel->{url};
		info(
			"[[  - >>uploading release #C{%s/%s}...",
			$rel->{name} // '?', $rel->{version} // '?'
		);
		my @args = ('upload-release', $rel->{url});
		push @args, '--sha1', $rel->{sha1} if $rel->{sha1};
		my (undef, $rc) = $bosh->execute(@args);
		# upload-release is idempotent (existing release/version is a no-op); a
		# non-zero rc therefore signals a genuine failure.
		error("Failed to upload runtime-config release %s", $rel->{name} // $rel->{url})
			if $rc;
	}
	return 1;
}

# }}}

# upload_stemcells - Upload a suitable stemcell to the just-deployed director {{{
# when it has none, OS-aware and pin-aware.
#
# This overrides the genesis-lib base class Genesis::Hook::PostDeploy::
# upload_stemcells, which resolves the stemcell OS from the raw manifest and
# falls back to ubuntu-jammy, and always uploads the *latest* version.  On a
# noble-only management director that silently uploaded an unrequested
# ubuntu-jammy stemcell; and because the bosh.io lookup was unguarded, a bosh.io
# outage crashed the whole deploy in the post-deploy hook.
#
# This kit-local version:
#   (a) is OS-aware  - honours params.stemcell_os, falling back to the OS of the
#       stemcell this director was actually deployed with (the manifest), then
#       the kit default.  A noble director therefore gets a noble stemcell even
#       when params.stemcell_os is not set;
#   (b) is pin-aware - honours params.stemcell_version, falling back to "latest";
#   (c) fails gracefully - warns (with a manual upload hint) instead of crashing
#       when the stemcell source is unreachable or the pin is unavailable.
sub upload_stemcells {
	my ($self) = @_;
	return unless $self->deploy_successful;

	my $env = $self->env;
	my $bosh = $env->get_target_bosh({self => 1});

	$env->notify("checking for stemcells on the BOSH director");
	my @existing = values $bosh->stemcells()->%*;
	if (@existing) {
		info(
			"[[  - >>found %s on the BOSH director",
			count_nouns(scalar @existing, 'existing stemcell')
		);
		return 1;
	}

	my $os = $self->_resolve_stemcell_os($env);
	my $version = $env->lookup('params.stemcell_version', 'latest');
	my $type = $env->lookup('bosh-configs.stemcells.type', undef);
	my $iaas = $env->iaas eq 'stackit' ? 'openstack' : $env->iaas;
	my $manual_hint = sprintf(
		"[[  >>#G{%s do upload-stemcells --os %s%s}",
		scalar $env->get_call_path_with_env, $os,
		($version eq 'latest' ? '' : " $version")
	);

	$env->notify(
		"determining available %s%s stemcells (target version #C{%s})...",
		$type ? "$type " : '', $os, $version
	);

	# The lookup reaches out to the stemcell index (bosh.io by default); guard it
	# so an outage warns rather than crashing the post-deploy hook.
	my @available = eval {
		require Service::BOSH::Stemcell;
		Service::BOSH::Stemcell->available_stemcells(
			iaas => $iaas,
			os   => $os,
			type => $type,
		);
	};
	if ($@ || !@available) {
		my $why = $@ ? do { (my $e = "$@") =~ s/\s+$//; $e } : 'none returned';
		warning(
			"Could not determine available %s stemcells for the %s IaaS (%s).\n".
			"Upload one manually once the source is reachable:\n%s",
			$os, $iaas, $why, $manual_hint
		);
		return 0;
	}

	my $selected = _select_stemcell($version, \@available);
	unless ($selected) {
		warning(
			"Requested stemcell version #C{%s} for %s was not found among the ".
			"available stemcells.  Upload one manually:\n%s",
			$version, $os, $manual_hint
		);
		return 0;
	}

	info(
		"[[  - >>uploading stemcell #C{%s/%s} to the BOSH director...",
		$selected->{name}, $selected->{version}
	);
	my $ok = eval { $selected->upload($bosh, dryrun => 0) };
	if (!$ok || $@) {
		my $err = $@ ? do { (my $e = "$@") =~ s/\s+$//; " ($e)" } : '';
		warning(
			"Failed to upload stemcell %s/%s%s.  Upload it manually:\n%s",
			$selected->{name}, $selected->{version}, $err, $manual_hint
		);
		return 0;
	}
	return 1;
}

# }}}

# _resolve_stemcell_os - Decide which stemcell OS to upload {{{
# Precedence: explicit params.stemcell_os, then the OS the director was actually
# deployed with (first manifest stemcell), then the kit default.  Reading the
# deployed manifest is what fixes the jammy-on-noble bug without requiring every
# environment to set params.stemcell_os.
use constant DEFAULT_STEMCELL_OS => 'ubuntu-jammy';
sub _resolve_stemcell_os {
	my ($self, $env) = @_;
	return $env->lookup('params.stemcell_os', undef)
		// ($env->manifest_lookup('stemcells', [])->[0] // {})->{os}
		// DEFAULT_STEMCELL_OS;
}

# }}}

# _select_stemcell - Pick the stemcell matching the requested version {{{
# Available stemcells are pre-sorted newest-first by the caller, so "latest" is
# the head of the list.  A pinned version selects the exact match or undef.
sub _select_stemcell {
	my ($version, $available) = @_;
	return undef unless $available && @$available;
	return $available->[0] if !defined($version) || $version eq 'latest';
	my ($match) = grep { defined($_->{version}) && $_->{version} eq $version } @$available;
	return $match;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
