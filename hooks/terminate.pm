package Genesis::Hook::Bosh::Terminate v3.2.0;
use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis;
use Genesis::UI qw/prompt_for_boolean/;
use Genesis::Term qw/bullet/;
use Genesis::Hook;

# Give us the bosh and credhub functions that target this director instead of
# parent director
Genesis::Hook::require_hook_lib;
require('BoshDirectorAccess.pm');
BoshDirectorAccess->import();

# Hook initialization
sub init {
  my $class = shift;
	$class->check_for_required_args({@_}, qw/env kit mode dryrun force noprompt/);
	my $obj = $class->SUPER::init(@_);
	# Make sure we're running with a compatible Genesis version
	$obj->check_minimum_genesis_version('3.1.0-rc.20'); 
  
	# Validate the mode
	bug(
		"Unknown termination mode '%s'; expected 'before', 'after', or 'failed'",
		$obj->{mode}
	) unless $obj->{mode} =~ /^(before|after|failed)$/;

	# If dry_run was passed in, it should be renamed to dryrun
	$obj->{dryrun} = delete $obj->{dry_run} if exists $obj->{dry_run};

	$obj->{completed} = 0;
	return $obj;
}

sub perform {
  my ($self) = @_;

  # Different handling based on when this hook is being executed
	my $mode = $self->{mode};
	return $self->_before_terminate() if $mode eq 'before';
	return $self->_after_terminate() if $mode eq 'after';
	return $self->_failed_terminate() if $mode eq 'failed';
	bug("Unknown termination mode: $mode");
}

# Executed before the BOSH deployment is deleted
sub _before_terminate {
  my ($self) = @_;

	unless ($self->use_create_env || $self->env->bosh->has_deployment($self->env->deployment_name)) {
		info(
			"Deployment #M{%s} does not exist on BOSH director #M{%s}",
			$self->env->deployment_name,
			$self->env->bosh->{alias}
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

	# Check if bosh is reachable
	info {pending=>1}, "Checking availability of the #M{%s} BOSH director...", $self->bosh->{alias};
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
	my $running_deployments = $self->read_json_from_bosh('deployments');
	if (@$running_deployments) {
		error(
			"\nThere are still deployments running on this BOSH director deployment:\n%s\n\n".
			"These deployments must be terminated before deleting this BOSH director deployments.",
			join("\n", map {bullet("#y{$_->{name}}")} @$running_deployments)
		);
		return $self->done(0); # TODO: Should this just bail, or return a complex structure with result and message?
	} else {
		info("\nNo deployments are running on this BOSH director -- it is safe to delete.");
	}

	# Bosh deployments need to be cleaned up before deletion
	my ($out, $rc, $err) = $self->bosh->cleanup(dryrun => $self->is_dryrun, all => 1);
	if ($rc != 0) {
		error("Failed to cleanup BOSH deployments: %s", $err) unless $self->is_dryrun;
		return $self->done(0);
	}

	# Return success
	return $self->done(1);
}

# Executed after a successful BOSH deployment deletion
sub _after_terminate {
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
	return $self->done(1);
}

# Executed if the BOSH deployment deletion failed
sub _failed_terminate {
  my ($self) = @_;

  warning("Termination failed - analyzing and attempting to recover...");

	# Do any analysis or potential recovery here
	# For example, if the deployment failed to delete, you might want to try again
	use Pry; pry;
  
	return $self->done(1);
}

sub is_dryrun {
	return $_[0]->{dryrun};
}

1;
