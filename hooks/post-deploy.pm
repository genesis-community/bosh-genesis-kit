package Genesis::Hook::PostDeploy::BOSH v4.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info error warning load_yaml_file/;

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
	}
	return $self->done(1);
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

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
