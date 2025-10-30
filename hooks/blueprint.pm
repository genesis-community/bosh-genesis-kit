package Genesis::Hook::Blueprint::BOSH v4.0.5;

use v5.20;    # Genesis min perl version is 5.20
use warnings;

# Only needed for development
BEGIN { push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME} . '/.genesis/lib' }
use parent qw(Genesis::Hook::Blueprint);

use Genesis qw/bail info warning error in_array new_enough/;

# init - Initialize the hook {{{
sub init {
	my $class = shift;
	my $obj   = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
	return $obj;
}

# }}}

# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;

	$self->add_files(
		qw(
		  bosh-deployment/bosh.yml
		  bosh-deployment/uaa.yml
		  bosh-deployment/credhub.yml
		  bosh-deployment/misc/dns.yml
		  bosh-deployment/misc/ntp.yml
		  bosh-deployment/misc/proxy.yml
		  bosh-deployment/misc/trusted-certs.yml
		)
	);

	# NOTE: This is until bosh-deployment is upgraded:
	$self->add_files("overlay/nats2.yml");
	my @valid_features = $self->want_feature('ocfp') ? qw(
		+proto skip-op-users vault-credhub-proxy external-db-no-tls okta
		s3-blobstore iam-instance-profile s3-blobstore-iam-instance-profile
		minio-blobstore node-exporter source-releases
		bosh-metrics bosh-lb bosh-dns-healthcheck ocfp
	) : qw(
		+proto skip-op-users vault-credhub-proxy external-db-no-tls okta
		s3-blobstore iam-instance-profile s3-blobstore-iam-instance-profile
		minio-blobstore node-exporter source-releases trust-blacksmith-ca
		blacksmith-integration doomsday-integration bosh-metrics bosh-lb
		bosh-dns-healthcheck netop-access sysop-access
	);


	# Features pre-check: Check for ops features
	my ( @features, $iaas, $db, $abort, $warn ) = ();
	for my $feature ( $self->features ) {
		if ( $feature =~ /^(aws|azure|google|openstack|stackit|vsphere|warden)(?:-(cpi|init))$/ ) {
			my $trimmed_feature = $1;
			my $type            = $2;
			if ( $self->iaas ) {
				$abort = 1;
				error(
					"The #c{%s} feature cannot be used because #c{%s} is already " .
					"selected as the cloud provider, specified in kit.iaas",
					$feature, $self->iaas
				);

			} elsif ( $trimmed_feature ne $feature ) {
				$abort = 1;
				if ( $type eq 'cpi' ) {
					error( "The #c{%s} feature has been renamed to #c{%s}",
						$feature, $trimmed_feature );

				} else {
					error(
						"The #c{%s} feature is no longer valid.  Please use #c{%s} instead, " .
						"and set the #c{genesis.use_create_env} parameter to #c{true} in " .
						"your environment file.",
						$feature, $trimmed_feature
					);
				}

			} elsif ($iaas) {
				$abort = 1;
				error(
					"The #c{%s} feature cannot be used because #c{%s} is already " .
					"selected as the cloud provider.",
					$trimmed_feature, $iaas
				);

			} else {
				$iaas = $trimmed_feature;
				push @features, $trimmed_feature;
			}

		} elsif ( $feature =~ /^(aws|azure|google|openstack|stackit|vsphere|warden)$/ ) {
			if ($iaas) {
				$abort = 1;
				error(
					"The #c{%s} feature cannot be used because #c{%s} is already " .
					"selected as the cloud provider.",
					$feature, $iaas
				);
			}
			else {
				$iaas = $feature;
				push @features, $feature;
			}
		}
		elsif ( $feature =~ /^external-db(?:|-(mysql|postgres))$/ ) {
			if ($db) {
				$abort = 1;
				error(
					"The #c{%s} feature cannot be used because #c{%s} is already " .
					"selected as the database.",
					$feature, $db
				);

			} elsif ( $self->is_ocfp ) {
				$abort = 1;
				error(
					"The #c{%s} feature cannot be used in an OCFP environment, as the " .
					"database configuration is part of the OCFP specification.",
					$feature
				);

			} else {
				$db = $feature;
				push @features, $feature;
			}

		} elsif ( $feature eq 'shield' ) {
			$warn = 1;
			warning(
				"The #c{shield} feature is no longer supported.  Instead, please add ".
				"the shield agent to your runtime configuration."
			);

		} elsif ( $feature eq 'external-db-ca' ) {
			$warn = 1;
			warning(
				"The functionality contained within the 'external-db-ca' has become ".
				"mandatory and has therefore been merged into the base kits ".
				"#c{external-db-postgres} and #c{external-db-mysql}. You can remove ".
				"the 'external-db-ca' feature without any changes occurring."
			);

		} elsif ( $feature =~ /^(proxy|credhub|registry)$/ ) {
			$warn = 1;
			warning(
				"You no longer need to explicitly specify the #c{%s} feature.  If you ".
				"remove it, everything will still work as expected."
			);

		} elsif ($self->want_feature('ocfp') && $feature =~ /trust-(blacksmith-ca|parent-bosh|bosh)/) {
			# these are now included as part of the ocfp feature
			$warn = 1;
			warning(
				"The #c{%s} feature is now included as part of the ocfp feature, ".
				"and can be removed from your features list.",
				$feature
			);

		} elsif ( in_array( $feature, @valid_features)) {
			push @features, $feature;

		} elsif ( $feature =~ /^\+/ ) {

			# virtual feature dynamically created based on other features/params
			push @features, $feature;
		}
		elsif ( $feature =~ /^bosh-deployment\/.*/ ) {
			if ( in_array( $feature, $self->{files} ) ) {
				# This doesn't work because we haven't processed the features yet
				warning(
					"%s is already included in the base manifest, and should not be " .
					"listed in the features list.",
					$feature
				);
				next;
			}
			if ( $self->kit_has_file("${feature}.yml") ) {
				push @features, $feature;

			} else {
				$abort = 1;
				error(
					"#c{%s} is not an upstream operation -- see bosh-deployment for " .
					"valid operations.",
					$feature
				);
			}
		}
		elsif ( -f $self->env->path("ops/${feature}.yml") ) {
			push @features, $feature;

		} else {
			$abort = 1;
			error(
				"The #c{%s} feature is invalid. See the manual for list of valid " . "features.",
				$feature
			);
		}
	}

	$iaas //= $self->iaas;

	# Check validity of given features
	unless ( defined($iaas) ) {
		$abort = 1;
		error(
			"No specified IaaS feature for this environment, expecting one of: aws, ".
			"azure, google, openstack, stackit, vsphere or warden.  Please specify this in the ".
			"#c{kit.iaas} section of your environment file."
		);
	}

	info(
		"Update your #C{%s} file to remove these warnings.\n", $self->relative_env_path
	) if $warn;

	bail(
		"#R{Cannot continue} - fix your #C{%s} file to resolve these issues.",
		$self->relative_env_path
	) if $abort;

	# Replace given features with the currated list
	$self->set_features(@features);

	$self->add_files('overlay/base-proto.yml') if $self->is_create_env;
	$self->add_files(qw(
		overlay/base.yml
		overlay/addons/prometheus-integration.yml
		overlay/upstream_version.yml
		overlay/addons/credhub.yml
	));

	# use source-releases instead of compiled releases
	$self->add_files(qw(
		bosh-deployment/misc/source-releases/bosh.yml
		bosh-deployment/misc/source-releases/credhub.yml
		bosh-deployment/misc/source-releases/uaa.yml
	)) if $self->want_feature('source-releases');

	$self->add_files(qw(
		bosh-deployment/jumpbox-user.yml
		overlay/addons/op-users.yml
	)) unless $self->want_feature('skip-op-users');

	# Process the IaaS to set a baseline
	if ( $iaas eq "warden" ) {
		bail("BOSH Warden CPI can not be deployed as a proto-BOSH") if $self->is_create_env;
		$self->add_files(qw(
			bosh-deployment/bosh-lite.yml
			overlay/cpis/warden.yml
			overlay/no-proto.yml
		));

	} elsif ( $iaas =~ /^(aws|azure|google|openstack|stackit|vsphere)$/ ) {
		my $cpi = ( $iaas eq 'google' ) ? 'gcp' : $iaas;
		if ( $self->kit_has_file("bosh-deployment/${cpi}/cpi.yml") ) {
			$self->add_files("bosh-deployment/${cpi}/cpi.yml");

		} elsif ( $self->kit_has_file("overlay/cpis/${cpi}-base.yml") ) {

			# If the cpi file is not in bosh-deployment, the base file can be
			# put in the overlay/cpis directory prior to it being accepted
			# into bosh-deployment.
			$self->add_files("overlay/cpis/${cpi}-base.yml");

		} else {
			bail(
				"Cannot find the cpi file for %s in the kit.  Please ensure you have " .
				"the correct kit for your IaaS.",
				$cpi
			);
		}
		$self->add_files("overlay/cpis/${cpi}.yml");
		$self->add_files("bosh-deployment/${cpi}/use-managed-disks.yml")   if $cpi eq 'azure';
		$self->add_files("bosh-deployment/openstack/boot-from-volume.yml") if $cpi eq 'openstack';
		$self->add_files(
			( $self->is_create_env )
			? "overlay/cpis/${cpi}-proto.yml"
			: "overlay/no-proto.yml"
		);
	}

	for my $feature ( $self->features ) {
		if ( $feature eq 'iam-instance-profile' ) {
			bail("Cannot use IAM instance profiles if not deploying to AWS") if $iaas ne 'aws';
			$self->add_file("overlay/addons/iam-profile.yml");

		} elsif ( $feature eq 's3-blobstore' ) {
			$self->add_files(qw(
				bosh-deployment/aws/s3-blobstore.yml
				overlay/addons/s3-blobstore.yml
			));
			if ( $self->want_feature("s3-blobstore-iam-instance-profile") ) {
				bail("Cannot use IAM instance profiles if not deploying to AWS") if $iaas ne 'aws';
				$self->add_files("overlay/addons/s3-blobstore-iam-profile.yml");
			}

		} elsif ( $feature eq 'minio-blobstore' ) {
			bail(
				"Can only specify one of: s3-blobstore, minio-blobstore"
			) if $self->want_feature('s3-blobstore');
			$self->add_files("overlay/addons/minio-blobstore.yml");

		} elsif ( $feature eq '+internal-blobstore' ) {
			$self->add_files("overlay/addons/internal-blobstore.yml");

		} elsif ( $feature =~ /^(external-db-mysql|external-db-postgres)$/ ) {
			$self->add_files(qw(
				overlay/addons/external-db-internal-db-cleanup.yml
				overlay/addons/external-db.yml
			));
			if ( $feature eq "external-db-mysql" ) {
				$self->add_files('overlay/addons/external-db-mysql.yml');
			}
			$self->add_files(
				$self->want_feature("external-db-no-tls")
				? "overlay/addons/external-db-no-tls.yml"
				: "overlay/addons/external-db-ca.yml"
			);

		} elsif ( $feature eq 'trust-blacksmith-ca' ) {
			$self->add_files('overlay/addons/trust-blacksmith-ca.yml')
				unless $self->want_feature("ocfp");

		} elsif ( $feature eq 'ocfp' ) {
			my $env = $self->env;
			my $env_type = $env->ocfp_type;
			# Default OCFP features
			$self->add_files(
				"ocfp/meta.yml",
				"ocfp/ocfp.yml",
				"ocfp/${iaas}/base.yml",
				"ocfp/${iaas}/${env_type}.yml",
				"overlay/addons/doomsday-integration.yml"
			);
			$self->remove_files( "overlay/cpis/${iaas}.yml", "overlay/cpis/${iaas}-proto.yml", );

			# First handle the iaas-specific files
			if ( $iaas eq 'aws' ) {
				$self->add_files(
					"ocfp/remove-internal-blobstore.yml",
					"bosh-deployment/aws/s3-blobstore.yml",
				) unless $self->want_feature("+internal-blobstore");

			} elsif ( $iaas eq 'google' ) {
				$self->add_files(
					"ocfp/remove-internal-blobstore.yml",
					"bosh-deployment/gcp/gcs-blobstore.yml",
				) unless $self->want_feature("+internal-blobstore");

			} elsif ( $iaas eq 'openstack' ) {    # Using internal blobstore initially
				$self->add_files(
					"ocfp/remove-internal-blobstore.yml",
					"ocfp/openstack/compatible-blobstore.yml",
				) unless $self->want_feature("+internal-blobstore");

			} elsif ( $iaas eq 'stackit' ) {      # Using internal blobstore initially
				$self->add_files(
					"ocfp/remove-internal-blobstore.yml",
					"ocfp/stackit/compatible-blobstore.yml",
				) unless $self->want_feature("+internal-blobstore");

			} else {
				$self->kit_bug(
					"The ocfp feature has not been implemented for the $iaas " . "infrastructure" );
			}

			# Automatically include trusted cas if they exist
			$self->add_files_if_secret_exists(
				($env->secrets_mount . '/certs/org:ca') => 'ocfp/trust-org-ca.yml'
			);
			$self->add_files_if_secret_exists(
				($env->secrets_base . 'ssl/ca') => 'ocfp/trust-bosh.yml'
			);

			if ($env_type ne 'mgmt') {
				$self->add_files(
					'ocfp/trust-parent-bosh.yml',
					'overlay/addons/blacksmith-integration.yml'
				);
				$self->add_files_if_secret_exists(
					$env->exodus_mount . $env->name . '/blacksmith:blacksmith_ca' =>
					'ocfp/trust-blacksmith-ca.yml'
				);
			}

			$self->add_files_if_wants("+ocfp-ext-db",
				"overlay/addons/external-db-internal-db-cleanup.yml",
				"ocfp/meta-external-db.yml",
				"ocfp/external-db.yml"
			);

			$self->add_files_if_wants("external-db-no-tls",
				"overlay/addons/external-db-no-tls.yml"
			);

			$self->add_files_if_wants('bosh-lb', 'ocfp/bosh-lb.yml');

			# End of OCFP mega-feature cluster

		} elsif ( basic_feature($feature) ) {
			$self->add_files("overlay/addons/${feature}.yml");
			$self->add_files_if_exists("overlay/releases/${feature}.yml");

		} elsif ( noop_feature($feature) ) {
			# Do nothing
			#

		} elsif ( $feature =~ /^bosh-deployment\/.*/ ) {
			next if in_array($feature, $self->{files});
			$self->add_files("${feature}.yml");

		} elsif ( -f $self->env->path("ops/${feature}.yml") ) {
			$self->add_files( $self->env->path("ops/${feature}.yml") );

		} else {
			$abort = 1;
			error( "The #c{%s} feature is invalid. See the manual for list of valid " . "features.",
				$feature );
		}
	}

	bail(
		"#R{Cannot continue} - fix your #C{%s} file to resolve these issues.",
		$self->relative_env_path,
	) if $abort;

	# Cleanup
	if ( $self->is_create_env ) {

		# If this is a `create-env` BOSH and one of the iam-instance-profile or
		# s3-blobstore-iam-instance-profile features are requested, then we need
		# to ensure the proto-BOSH has the correct cloud properties
		$self->add_files(
			"bosh-deployment/aws/cli-iam-instance-profile.yml",
			"overlay/addons/proto-iam-profile.yml"
		) if $self->want_feature("iam-instance-profile") || $self->want_feature("s3-blobstore-iam-instance-profile");
	}

	# Use params.availability_zones if set, otherwise default to "z1"
	$self->add_files("overlay/set-availability-zone.yml");

	# Upgrade check
	my $prev_version = $self->env->exodus_lookup( "kit_version", "" );
	bail(
		"Detected previous deployment of BOSH kit v%s- please upgrade to at " .
		"least bosh kit 2.3.0 before upgrading to > 3.0.0"
	) if $prev_version ne "" && !new_enough( $prev_version, "2.2.7-rc.0" );

	return $self->done;
}

# }}}

# Support methods {{{
my $_basic_features = {map { ( $_, 1 ) } qw(
	vault-credhub-proxy node-exporter bosh-metrics okta blacksmith-integration
	doomsday-integration
)};
sub basic_feature { return $_basic_features->{ $_[0] }; }

my $_noop_features = {map { ( $_, 1 ) } qw(
	+proto source-releases s3-blobstore-iam-instance-profile external-db-no-tls
	skip-op-users bosh-dns-healthcheck netop-access sysop-access toolbelt
	+aws-secret-access-keys +s3-blobstore-secret-access-keys +external-db
	+ocfp-ext-db +internal-database +blacksmith-credentials +doomsday-credentials
)};
sub noop_feature { return $_noop_features->{ $_[0] } }

sub is_create_env {
	return $_[0]->env->use_create_env;
}

sub add_files_if_secret_exists {
	my ( $self, $path_to_check, @files ) = @_;
	$self->add_files(@files) if $self->env->vault->has($path_to_check);
}

# }}}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
