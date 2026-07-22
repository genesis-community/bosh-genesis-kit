package Genesis::Hook::Terminate::BOSH v4.1.0;
use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Terminate);

use Genesis;
use Genesis::UI qw/prompt_for_boolean/;
use Genesis::Term qw/bullet/;

# Hook initialization
sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	# Make sure we're running with a compatible Genesis version
	$obj->check_minimum_genesis_version('3.1.0-rc.20');
	return $obj;
}

# Using the Genesis::Hook::Terminate class's perform method to handle the
# termination process, which requires the following methods to be defined:
#   - before_terminate
#   - after_terminate
#   - failed_terminate

# Executed before the BOSH deployment is deleted
sub before_terminate {
	my ($self) = @_;

	unless ($self->use_create_env || $self->parent_bosh->has_deployment($self->env->deployment_name)) {
		info(
			"Deployment #M{%s} does not exist on BOSH director #M{%s}",
			$self->env->deployment_name,
			$self->env->parent_bosh->{alias}
		);
		my $continue = 0;
		my $msg = "Skipping the clean-up steps on the non-existent BOSH director.";
		if ($self->{force}) {
			$msg = "Allowing attempt to terminate anyway due to --force.  $msg";
			$continue = 1;
		} elsif (! $self->{noprompt}) {
			$continue = prompt_for_boolean("$msg\nDo you want to continue with the termination process?", "n");
		}
		warning($msg) if $continue;
		return $self->done($continue);
	}

	# Check if this bosh is reachable
	info({pending=>1},
		"Checking availability of the #M{%s} BOSH director...",
		$self->bosh->{alias}
	);
	my $status = $self->bosh->status;
	info(
		"#%s{%s} - %s",
		$status->{status} eq 'ok' ? 'g' : 'r',
		$status->{status},
		$status->{msg}
	);
	if ($status->{status} ne 'ok') {
		my $msg =
		"Cannot connect to BOSH director, so unable to verify it doesn't have any ".
		"unreleased deployments or resources.";
		if ($self->{force}) {
			if ($self->{noprompt}) {
				error(
					"$msg\n\nWhile --force was specified, not able to confirm user intent ".
					"due to --yes option, so not continuing due to the potential negative ".
					"impact.  (Run again without --yes to manually confirm.)"
				);
				return $self->done(0);
			} else {
				warning($msg);
				my $continue = prompt_for_boolean(
					"This may leave untracked resource usage on your infrastructure if ".
					"you haven't manually cleaned them up.  Attempt to terminate anyway? ".
					"[y|n]",
					'n'
				);
				return $self->done($continue);
			}
		} else {
			error($msg);
			return $self->done(0);
		}
	}

	# For a BOSH kit, we need to make sure that there are no deployments still running
	my $running_deployments = $self->bosh->deployments;
	if (keys %$running_deployments) {
		error(
			"\nThere are still deployments running on this BOSH director deployment:\n%s\n\n".
			"These deployments must be terminated before deleting this BOSH director deployments.",
			join("\n", map {bullet("#y{$_}")} keys %$running_deployments)
		);
		return $self->done(0); # TODO: Should this just bail, or return a complex structure with result and message?
	} else {
		info("\nNo deployments are running on this BOSH director -- it is safe to delete.");
	}

	# Clean up orphaned BOSH resources (releases/stemcells/disks) before deletion.
	# This only matters for a director-deployed BOSH, where those resources linger
	# on the parent director after the deployment is gone.  A create-env (proto)
	# BOSH is removed wholesale by delete-env -- VM and persistent disk together --
	# so a pre-delete clean-up is redundant and only risks blocking the teardown
	# on a transient/stale resource (e.g. a stemcell template whose VM is already
	# gone).  Skip it entirely for create-env.
	unless ($self->use_create_env) {
		my ($out, $rc, $err) = $self->bosh->cleanup(dryrun => $self->is_dryrun, all => 1);
		# Clean-up is best-effort: an error here (e.g. an already-removed stemcell
		# template) must not abort tearing the director down.  Warn and proceed,
		# but remember the failure so after_terminate can repeat it as the last
		# thing the operator sees -- a mid-teardown warning scrolls away, and
		# orphaned releases/stemcells/disks silently accrue against quota.
		if ($rc != 0 && !$self->is_dryrun) {
			$self->{__cleanup_failed} = $err // 'see BOSH task output above';
			warning(
				"Clean-up of orphaned BOSH resources reported errors; ".
				"continuing with termination: %s",
				$self->{__cleanup_failed}
			);
		}
	}

	# Return success
	return $self->done(1);
}

# Executed after a successful BOSH deployment deletion
sub after_terminate {
	my ($self) = @_;

	# If successful, we need to clean up the network claims in exodus data.
	if ($self->is_dryrun) {
		dryrun(
			"Would have cleaned up network definition and claims in #M{%s/%s} exodus data",
			$self->env->name,
			$self->env->type,
		);
	} else {
		info(
			"Cleaning up network definition and claims in #M{%s/%s} exodus data",
			$self->env->name,
			$self->env->type
		);
		$self->env->vault->clear($self->env->exodus_base.'/network');
	}

	# The pre-delete clean-up is best-effort (see before_terminate); if it
	# failed, repeat that here so it is the last thing the operator sees
	# rather than a warning buried above the deletion output.
	if ($self->{__cleanup_failed}) {
		warning(
			"The pre-delete clean-up of orphaned BOSH resources #R{failed}, and ".
			"the director has since been deleted, so anything it left behind - ".
			"stemcell images, orphaned persistent disks - now sits on the IaaS ".
			"with #R{no director tracking it}.  Audit your IaaS for artifacts ".
			"created by this director and remove them there.\n".
			"Original clean-up error: %s",
			$self->{__cleanup_failed}
		);
	}
	return $self->done(1);
}

# Executed if the BOSH deployment deletion failed
sub failed_terminate {
	my ($self, $data) = @_;

	warning("Termination failed - analyzing and attempting to recover...");

	# Do any analysis or potential recovery here
	# If Pry is available, drop into a REPL for debugging
	my $has_pry = eval { require Pry; 1; };
	if ($has_pry) {
		info("Starting Pry debugger session...");
		Pry::pry();
	} else {
		warning("Pry module not available for debugging - install with 'cpanm Pry'");
		error("Termination failed and could not start debugging session");
	}
	return $self->done(1);
}

# When dealing with a BOSH deployment, the identity of what is `bosh` can be
# ambiguous.  To clarify, we have two different BOSH directors:
#   - The BOSH director that is the target of the current environment
#   - The parent BOSH director that is the target of the parent environment
# The `bosh` method will return the BOSH director that is the current
# environment, while the `parent_bosh` method will return the BOSH director
# that deployed the current environment.
sub bosh {
	my $self = shift;
	return $self->{__bosh} ||= sub {
		return scalar $self->env->get_target_bosh({self => 1});
	}->();
}

sub parent_bosh {
	my $self = shift;
	# If the environment is a create-env, we don't have a parent BOSH
	return undef if $self->use_create_env;
	return $self->{__parent_bosh} ||= sub {
		return scalar $self->env->get_target_bosh({parent => 1});
	}->();
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
