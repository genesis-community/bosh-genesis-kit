package Genesis::Hook::Features::Bosh v2.1.0;

use strict;
use warnings;

my $lib;
BEGIN {$lib = $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use lib $lib;

use parent qw(Genesis::Hook);

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.4');
	$obj->{all_features} = [];
	$obj->{has_feature} = {};
	return $obj;
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	for my $feature (split /\s+/, $ENV{GENESIS_REQUESTED_FEATURES}) {
		bail(
			"Cannot specify a virtual feature: please specify $feature without the ".
			"preceeding '+' to position it in the feature list."
		) if ($feature =~ /^\+(.*)$/);
		$feature = 'external-db-postgres' if $feature eq 'external-db'; # feature renamed
		$self->add_feature($feature);
	}

	if ($self->has_feature('aws') || $self->has_feature('aws-cpi')) {
		$self->add_feature('+aws-secret-access-keys',!$self->has_feature('iam-instance-profile'));
		if ($self->has_feature('s3-blobstore')) {
			$self->add_feature('+s3-blobstore-secret-access-keys',!$self->has_feature('s3-blobstore-iam-instance-profile'));
		}
	} else {
		$self->add_feature('+s3-blobstore-secret-access-keys',$self->has_feature('s3-blobstore'));
	}

	if ($self->has_feature('ocfp')) {
		$self->add_feature('+internal-blobstore',$self->has_feature('internal-blobstore'));
		bail(
			"Invalid feature 'external-db-no-tls' while specifying 'internal-db' feature."
		) if $self->has_feature('internal-db') && $self->has_feature('external-db-no-tls');
		$self->add_feature('+ocfp-ext-db') unless ($self->delete_feature('internal-db'));
	} else {
		bail(
			"Invalid feature 'internal-db' without 'ocfp' feature."
		) if $self->has_feature('internal-db');
		$self->add_feature('+internal-blobstore',$self->has_feature('s3-blobstore') || $self->has_feature('minio-blobstore'));
		$self->add_feature('+external-db',$self->has_feature('external-db-postgres') || $self->has_feature('external-db-mysql'));
	}

	my $virtual_features = [ "aws-secret-access-keys", "s3-blobstore", "internal-blobstore", "external-db" ];
	my @results = ();
	for my $feature (@{$self->{all_features}}) {
		if (grep { $feature eq $_ } @$virtual_features) {
			if ($self->has_feature("+$feature")) {
				push @results, "+$feature";
				$self->delete_feature("+$feature");
			}
		} elsif ($self->has_feature($feature)) {
			push @results, $feature ;
			$self->delete_feature($feature);
		}
	}

	$self->done(\@results);
}

sub add_feature {
	my ($self, $feature, $set) = @_;
	$set = 1 if (@_) < 3;
	push @{$self->{all_features}}, $feature;
	$self->{has_feature}{$feature} = $set;
}

sub has_feature {
	my ($self, $feature) = @_;
	return $self->{has_feature}{$feature};
}

sub delete_feature {
	my ($self, $feature) = @_;
	return delete $self->{has_feature}{$feature};
}
