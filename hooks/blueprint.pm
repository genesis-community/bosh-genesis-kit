#!/usr/bin/env perl
package Genesis::Hook::Blueprint::Bosh v3.0.4;

use strict;
use warnings;

# Only needed for development
my $lib;
BEGIN {$lib = $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use lib $lib;

use parent qw(Genesis::Hook::Blueprint);

use Genesis qw/bail info warning error in_array new_enough/;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->{features} = [$obj->env->features];
	$obj->{files} = [];
	$obj->check_minimum_genesis_version('3.0.0-rc.1');
	return $obj;
}

sub perform {
	my ($blueprint) = @_; # $blueprint is '$self'

	$blueprint->{ocfp_env_type} = '';
	if ($blueprint->want_feature('ocfp')) {
		$blueprint->{ocfp_env_type} = ($blueprint->env->name =~ /.*-mgmt.*/)
			? 'mgmt'
			: 'ocf'
	}

	$blueprint->add_files(qw(
		bosh-deployment/bosh.yml
		bosh-deployment/uaa.yml
		bosh-deployment/credhub.yml
		bosh-deployment/misc/dns.yml
		bosh-deployment/misc/ntp.yml
		bosh-deployment/misc/proxy.yml
		bosh-deployment/misc/trusted-certs.yml
	));

	# NOTE: This is until bosh-deployment is upgraded:
	$blueprint->add_files("overlay/nats2.yml");

	# Features pre-check: Check for ops features
	my (@features,$iaas,$db,$abort,$warn) = ();
	for my $feature ($blueprint->features) {
		if ($feature =~ /^(aws|azure|google|openstack|vsphere|warden)-cpi$/) {
			my $trimmed_feature = $1;
			$warn = 1;
			warning(
				"The #c{%s} feature has been renamed to #c{%s}",
				$feature, $trimmed_feature
			);
			if ($iaas) {
				$abort = 1;
				error(
					"The #c{%s} feature cannot be used because #c{%s} is already ".
					"selected as the cloud provider.",
					$trimmed_feature, $iaas
				)
			} else {
				$iaas = $trimmed_feature;
				push @features, $trimmed_feature;
			}
		} elsif ($feature =~ /^(aws|azure|google|openstack|vsphere|bosh)-init$/) {
			my $trimmed_feature = $1;
			$warn = 1;
			warning(
				"The #c{%s} feature is now two separate features: #c{%s} and #c{proto}",
				$feature, $trimmed_feature
			);
			if ($iaas) {
				$abort = 1;
				error(
					"The #c{%s} feature cannot be used because #c{%s} is already ".
					"selected as the cloud provider.",
					$trimmed_feature, $iaas
				)
			} else {
				$iaas = $trimmed_feature;
				push @features, $trimmed_feature, 'proto';
			}
		} elsif ($feature =~ /^(aws|azure|google|openstack|vsphere|warden)$/) {
			if ($iaas) {
				$abort = 1;
				error(
					"The #c{%s} feature cannot be used because #c{%s} is already ".
					"selected as the cloud provider.",
					$feature, $iaas
				)
			} else {
				$iaas = $feature;
				push @features, $feature;
			}
		} elsif ($feature eq 'ocfp') {
			if ($db) {
				$abort = 1;
				error(
					"The #c{%s} feature cannot be used because #c{%s} is already ".
					"selected as the database.",
					$feature, $db
				);
			} else {
				$db = $feature;
				push @features, $feature;
			}
		} elsif ($feature =~ /^external-db(?:|-(mysql|postgres))$/) {
			if ($db) {
				$abort = 1;
				error(
					"The #c{%s} feature cannot be used because #c{%s} is already ".
					"selected as the database.",
					$feature, $db
				);
			} else {
				$db = $feature;
				push @features, $feature;
			}
		} elsif ($feature eq 'shield') {
			$warn = 1;
			warning(
				"The #c{shield} feature is no longer supported.  Instead, please add ".
				"the shield agent to your runtime configuration."
			);
		} elsif ($feature eq 'external-db-ca') {
			$warn = 1;
			warning(
				"The functionality contained within the 'external-db-ca' has become ".
				"mandatory and has therefore been merged into the base kits ".
				"#c{external-db-postgres} and #c{external-db-mysql}. You can remove ".
				"the 'external-db-ca' feature without any changes occurring."
			);
		} elsif ($feature =~ /^(proxy|credhub|registry)$/) {
			$warn = 1;
			warning(
				"You no longer need to explicitly specify the #c{%s} feature.  If you ".
				"remove it, everything will still work as expected."
			);
		} elsif (in_array($feature, qw(
			proto skip-op-users vault-credhub-proxy external-db-no-tls okta
			s3-blobstore iam-instance-profile s3-blobstore-iam-instance-profile
			minio-blobstore node-exporter trust-blacksmith-ca source-releases
			blacksmith-integration doomsday-integration bosh-metrics bosh-lb
			bosh-dns-healthcheck netop-access sysop-access
		))) {
			push @features, $feature
		} elsif ($feature =~ /^\+/) {
			# virtual feature dynamically created based on other features/params
			push @features, $feature
		} elsif ($feature =~ /^bosh-deployment\/.*/) {
			if (in_array($feature, $blueprint->files)) {
				warning(
					"%s is already included in the base manifest, and should not be ".
					"listed in the features list.",
					$feature
				);
				next;
			}
			if (-f "${feature}.yml") {
				push @features, $feature;
			} else {
				$abort = 1;
				error(
					"#c{%s} is not an upstream operation -- see bosh-deployment for ".
					"valid operations.",
					$feature
				);
			} 
		} elsif ( -f $blueprint->env->path("ops/${feature}.yml")) {
			push @features, $feature
		} else {
			$abort = 1;
			error(
				"The #c{%s} feature is invalid. See the manual for list of valid ".
				"features.",
				$feature
			)
		}
	}

	# Check validity of given features
	unless (defined($iaas)) {
		$abort = 1;
		error(
			"No specified IaaS feature for this environment, expecting one of: aws, ".
			"azure, google, openstack, vsphere or warden"
		)
	}
	
	bail(
		"#R{Cannot continue} - fix your #C{%s} file to resolve these issues.",
		$blueprint->relative_env_path,
	) if $abort;
	info(
		"Update your #C{%s} file to remove these warnings.\n",
		$blueprint->relative_env_path
	) if $warn;

	# Replace given features with the currated list
	$blueprint->set_features(@features);

	$blueprint->add_files('overlay/base-proto.yml') if $blueprint->is_create_env;
	$blueprint->add_files(qw(
		overlay/base.yml
		overlay/upstream_version.yml
		overlay/addons/credhub.yml
	));

	# use source-releases instead of compiled releases
	$blueprint->add_files(qw(
		bosh-deployment/misc/source-releases/bosh.yml
		bosh-deployment/misc/source-releases/credhub.yml
		bosh-deployment/misc/source-releases/uaa.yml
	)) if $blueprint->want_feature('source-releases');

	$blueprint->add_files(qw(
		bosh-deployment/jumpbox-user.yml
		overlay/addons/op-users.yml
	)) unless $blueprint->want_feature('skip-op-users');

	for my $feature ($blueprint->features) {
		if ($feature eq "warden") {
			bail(
				"BOSH Warden CPI can not be deployed as a proto-BOSH"
			) if $blueprint->is_create_env;
			$blueprint->add_files(qw(
				bosh-deployment/bosh-lite.yml
				overlay/cpis/warden.yml
				overlay/no-proto.yml
			));
		} elsif ($feature =~ /^(aws|azure|google|openstack|vsphere)$/) {
			my $cpi = ($feature eq 'google') ? 'gcp' : $feature;
			$blueprint->add_files(
				"bosh-deployment/${cpi}/cpi.yml",
				"overlay/cpis/${cpi}.yml"
			);
			$blueprint->add_files(
				"bosh-deployment/${cpi}/use-managed-disks.yml"
			) if $cpi eq 'azure';
      $blueprint->add_files(
				($blueprint->is_create_env) 
				? "overlay/cpis/${cpi}-proto.yml"
				: "overlay/no-proto.yml"
			);
		} elsif ($feature eq 'iam-instance-profile') {
			bail(
				"Cannot use IAM instance profiles if not deploying to AWS"
			) if $iaas eq 'aws';
			$blueprint->add_file("overlay/addons/iam-profile.yml");
		} elsif ($feature eq 's3-blobstore') {
			$blueprint->add_files(qw(
				bosh-deployment/aws/s3-blobstore.yml
				overlay/addons/s3-blobstore.yml
			));
			if ($blueprint->want_feature("s3-blobstore-iam-instance-profile")) {
				bail(
					"Cannot use IAM instance profiles if not deploying to AWS"
				) if $iaas eq 'aws';
				$blueprint->add_files("overlay/addons/s3-blobstore-iam-profile.yml");
			}
		} elsif ($feature eq 'minio-blobstore') {
			bail(
				"Can only specify one of: s3-blobstore, minio-blobstore"
			) if $blueprint->want_feature('s3-blobstore');
			$blueprint->add_files("overlay/addons/minio-blobstore.yml");
		} elsif ($feature eq '+internal-blobstore') {
			$blueprint->add_files("overlay/addons/internal-blobstore.yml")
		} elsif ($feature =~ /^(external-db-mysql|external-db-postgres)$/) {
			$blueprint->add_files(qw(
				overlay/addons/external-db-internal-db-cleanup.yml
				overlay/addons/external-db.yml
			));
			if ($feature eq "external-db-mysql") {
				$blueprint->add_files('overlay/addons/external-db-mysql.yml');
			}
			$blueprint->add_files(
				$blueprint->want_feature("external-db-no-tls")
					? "overlay/addons/external-db-no-tls.yml"
					: "overlay/addons/external-db-ca.yml"
			);
		} elsif ($feature eq 'trust-blacksmith-ca') {
			$blueprint->add_files(
				$blueprint->want_feature("ocfp")
				?	"ocfp/trust-blacksmith-ca.yml"
				:"overlay/addons/trust-blacksmith-ca.yml"
			);
		} elsif ($feature eq 'ocfp') {
			if ($iaas eq 'aws') {
				$blueprint->add_files( 
					"ocfp/remove-internal-blobstore.yml",
					"bosh-deployment/aws/s3-blobstore.yml" 
				)
			} elsif ($iaas eq 'google') {
				$blueprint->add_files( 
					"ocfp/remove-internal-blobstore.yml",
					"bosh-deployment/gcp/gcs-blobstore.yml" 
				)
			} else {
				$blueprint->kit->kit_bug(
					"The ocfp feature has not been implemented for the $iaas ".
					"infrastructure"
				)
			}

			my $env_type = $blueprint->{ocfp_env_type};
			$blueprint->add_files(
				"ocfp/meta.yml",
				"ocfp/ocfp.yml",
				"ocfp/${iaas}/${env_type}.yml",
				"overlay/addons/external-db-internal-db-cleanup.yml",
				"ocfp/external-db.yml"
			);

			$blueprint->add_files(
				"overlay/addons/external-db-no-tls.yml"
			) if $blueprint->want_feature("external-db-no-tls");

			$blueprint->add_files(
				"ocfp/bosh-lb.yml"
			) if $blueprint->want_feature("bosh-lb");
		} elsif (basic_feature($feature)) {
			$blueprint->add_files("overlay/addons/${feature}.yml");
			$blueprint->add_files("overlay/releases/${feature}.yml")
				if -f $blueprint->kit->path("overlay/releases/${feature}.yml");
		} elsif (noop_feature($feature)) {
			# Do nothing
		} elsif ($feature =~ /^bosh-deployment\/.*/) {
			warning(
				"Upstream $feature is already included in the manifest, possibly as ".
				"part of another feature.  Please remove it from the #yi{kit.features} ".
				"list."
			) if (in_array($feature, $blueprint->files));
			$blueprint->add_files("$feature");
		} elsif ( -f $blueprint->env->path("ops/${feature}.yml")) {
			push @features, $feature
		} else {
			$abort = 1;
			error(
				"The #c{%s} feature is invalid. See the manual for list of valid ".
				"features.",
				$feature
			)
		}
	}

	# Cleanup
	if ($blueprint->is_create_env) {
		# If this is a `create-env` BOSH and one of the iam-instance-profile or
		# s3-blobstore-iam-instance-profile features are requested, then we need
		# to ensure the proto-BOSH has the correct cloud properties
		$blueprint->add_files(
			"bosh-deployment/aws/cli-iam-instance-profile.yml",
			"overlay/addons/proto-iam-profile.yml"
		) if $blueprint->want_feature("iam-instance-profile") 
			|| $blueprint->want_feature("s3-blobstore-iam-instance-profile");
	}

	# Use params.availability_zones if set, otherwise default to "z1"
	$blueprint->add_files("overlay/set-availability-zone.yml");

	# Upgrade check
	my $prev_version = $blueprint->env->exodus_lookup("kit_version","");
	bail(
		"Detected previous deployment of BOSH kit v%s- please upgrade to at ".
		"least bosh kit 2.3.0 before upgrading to > 3.0.0"
	) if ($prev_version ne "" && ! new_enough($prev_version,"2.2.7-rc.0"));

	return $blueprint->done;
}

# Support methods
my $_basic_features = {
	map {($_,1)} qw(
		vault-credhub-proxy node-exporter bosh-metrics okta blacksmith-integration
		doomsday-integration) };
sub basic_feature { return $_basic_features->{$_[0]}; }

my $_noop_features = {
	map {($_,1)} qw(
		proto source-releases s3-blobstore-iam-instance-profile external-db-no-tls
		skip-op-users bosh-dns-healthcheck netop-access sysop-access toolbelt
		+aws-secret-access-keys +s3-blobstore-secret-access-keys +external-db) };
sub noop_feature { return $_noop_features->{$_[0]} }

sub is_create_env {
	my $self = shift;

	# v2.8.x method - overrides all other methods
	my $use_create_env = $self->env->lookup('genesis.use_create_env');
	if ($use_create_env) {
		return !!($use_create_env =~ /^(1|enable|on|true|yes)$/);
	} elsif ($self->{ocfp_env_type} eq "mgmt") {
		# OCFP management automatic method
		return 1;
	} 

	# Classic method
	$self->want_feature("proto")
}
1;
