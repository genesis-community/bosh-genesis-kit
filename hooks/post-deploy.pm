package Genesis::Hook::PostDeploy::BOSH v4.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info error warning run load_yaml_file/;

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

# _post_deploy_steps - the post-deployment steps, in execution order {{{
#
# Each step is a hashref: {id, label, method, retry, needs}.  The retry
# command is what the operator runs to complete that step by hand once the
# cause is fixed, and it is the reason this list carries labels at all: the
# bail genesis prints when a hook fails names only the hook, so anything
# the operator needs in order to recover has to come from here.
#
# `needs` maps a prerequisite step id to the policy applied when that
# prerequisite fails (or was itself blocked):
#
#   skip  - do not run this step; report it as blocked, with its retry
#           command, and block anything that in turn needs it
#   run   - run anyway, recording a note that a prerequisite had failed
#   abort - stop the whole post-deploy at this point
#
# List order is execution order and therefore also the dependency order:
# `needs` may only reference earlier ids (validated at run time).
#
# The one edge today: the dns runtime config names the bosh-dns release,
# but `bosh update-runtime-config` does not verify releases exist -- that
# happens at workload-deploy time.  Uploading the release first and
# blocking the config on it means the director can never hold a dns config
# whose release is missing, the state that surfaces much later as
# "Release 'bosh-dns' doesn't exist" on the first workload deploy.  The
# reverse failure (release present, config absent) is harmless.
#
# Note that update_director_network_config reports failure by bailing from
# inside the cloud-config hook rather than by returning, so its result is
# always undef today.  It is listed anyway: the list is what makes the set
# of post-deploy steps explicit, and if the base class ever grows a return
# value it is already wired up.
sub _post_deploy_steps {
	return (
		{ id     => 'cpi-config',
			label  => 'cpi-config upload',
			method => 'upload_director_cpi_config',
			retry  => '%s deploy' },
		{ id     => 'cloud-config',
			label  => 'director network space + cloud-config',
			method => 'update_director_network_config',
			retry  => '%s deploy' },
		{ id     => 'rc-releases',
			label  => 'runtime-config releases',
			method => 'upload_runtime_config_releases',
			retry  => '%s deploy' },
		{ id     => 'dns-rc',
			label  => 'bosh-dns runtime config',
			method => '_upload_dns_runtime_config',
			retry  => '%s do rc dns -y',
			needs  => { 'rc-releases' => 'skip' } },
		{ id     => 'stemcells',
			label  => 'stemcell upload',
			method => 'upload_stemcells',
			retry  => '%s do upload-stemcells' },
	);
}

# }}}
# _validate_post_deploy_steps - reject malformed step lists {{{
#
# Violations here are developer errors in the list above, not runtime
# conditions, so they die immediately rather than turning into a
# half-executed post-deploy.
sub _validate_post_deploy_steps {
	my ($self, @steps) = @_;
	my %seen;
	for my $step (@steps) {
		for my $key (qw/id label method retry/) {
			die "post-deploy step is missing '$key'\n" unless defined $step->{$key};
		}
		my $id = $step->{id};
		die "duplicate post-deploy step id '$id'\n" if $seen{$id}++;
		for my $dep (sort keys %{$step->{needs} // {}}) {
			die "post-deploy step '$id' needs '$dep', which is not an earlier step\n"
				unless $seen{$dep};
			my $policy = $step->{needs}{$dep};
			die "post-deploy step '$id' has unknown policy '$policy' for '$dep'\n"
				unless $policy =~ /^(skip|run|abort)$/;
		}
	}
	return 1;
}

# }}}
# _run_post_deploy_steps - execute steps, honouring dependency policies {{{
#
# Returns {failed, skipped, notes, aborted}: failed and skipped are lists
# of {id, label, retry} (skipped entries add `because`, the id of the
# blocking step, or 'abort'); notes are {id, label, because} for steps
# that ran under a `run` policy despite a failed prerequisite; aborted is
# the id of the step whose abort edge fired, if any.
#
# Genesis' convention for step methods is 1 on success, 0 on failure, and
# a bare return (undef) for "nothing to do" -- upload_stemcells returns
# undef when an operator declines the interactive prompt, so only a
# DEFINED false result is a failure, and a noop never blocks dependents.
sub _run_post_deploy_steps {
	my ($self, @steps) = @_;
	$self->_validate_post_deploy_steps(@steps);

	my (%status, @failed, @skipped, @notes, $aborted);
	STEP: for my $i (0..$#steps) {
		my $step = $steps[$i];
		my ($id, $label, $retry) = @{$step}{qw/id label retry/};
		for my $dep (sort keys %{$step->{needs} // {}}) {
			next unless ($status{$dep} // '') =~ /^(failed|skipped)$/;
			my $policy = $step->{needs}{$dep};
			if ($policy eq 'abort') {
				$aborted = $id;
				push @skipped, map {
					+{id => $_->{id}, label => $_->{label}, retry => $_->{retry},
						because => 'abort'}
				} @steps[$i..$#steps];
				last STEP;
			} elsif ($policy eq 'skip') {
				$status{$id} = 'skipped';
				push @skipped, {id => $id, label => $label, retry => $retry,
					because => $dep};
				next STEP;
			} else { # run
				push @notes, {id => $id, label => $label, because => $dep};
			}
		}
		my $method = $step->{method};
		my $result = $self->$method();
		$status{$id} = !defined($result) ? 'noop' : $result ? 'ok' : 'failed';
		push @failed, {id => $id, label => $label, retry => $retry}
			if $status{$id} eq 'failed';
	}
	return {
		failed  => \@failed,
		skipped => \@skipped,
		notes   => \@notes,
		aborted => $aborted,
	};
}

# }}}
# perform - Execute post-deployment tasks for BOSH environments {{{
sub perform {
	my ($self) = @_;
	my $report;
	if ($self->deploy_successful) {
		my $env = $self->env;

		# Run the steps under their dependency policies, collecting what
		# failed and what was blocked rather than stopping at the first
		# failure: an operator who has to come back and finish by hand
		# wants the whole list.
		$report = $self->_run_post_deploy_steps($self->_post_deploy_steps);

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

	my @failed  = @{ $report ? $report->{failed}  : [] };
	my @skipped = @{ $report ? $report->{skipped} : [] };
	return $self->done(1) unless @failed || @skipped;

	# The director is deployed and its exodus data is already recorded; what
	# failed is the configuration applied to it afterwards.  Returning false
	# makes genesis bail, so this exits non-zero instead of leaving a
	# half-configured director behind a successful-looking deploy -- the
	# failure otherwise resurfaces much later as an unrelated-looking error
	# in the first workload deployed against it.  A skipped step counts the
	# same way: it is work the director is still missing, deliberately not
	# attempted because its prerequisite failed.
	my %label = map {($_->{id} => $_->{label})} @failed, @skipped;
	my $cmd = $self->env->get_call_path_with_env;
	error(
		"\nThe deployment succeeded, but %d post-deploy step(s) did not:\n%s\n\n".
		"The director is up and its exodus data is recorded.  Fix the cause, ".
		"then either re-run the deploy or complete the steps individually with ".
		"the commands above.",
		scalar(@failed) + scalar(@skipped),
		join("\n",
			(map {
				sprintf("[[  - >>#R{%s} - retry with #G{%s}",
					$_->{label}, sprintf($_->{retry}, $cmd))
			} @failed),
			(map {
				sprintf("[[  - >>#Y{%s} - not run (%s); once fixed, #G{%s}",
					$_->{label},
					$_->{because} eq 'abort'
						? 'post-deploy aborted'
						: 'blocked by '.($label{$_->{because}} // $_->{because}),
					sprintf($_->{retry}, $cmd))
			} @skipped),
		)
	);

	return $self->done(0);
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

	my $ok = 1;
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
		# non-zero rc therefore signals a genuine failure.  Every release is
		# attempted before reporting, so one unreachable URL does not hide
		# the state of the rest.
		if ($rc) {
			error("Failed to upload runtime-config release %s", $rel->{name} // $rel->{url});
			$ok = 0;
		}
	}
	return $ok;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
