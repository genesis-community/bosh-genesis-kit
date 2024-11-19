package BoshDirectorAccess;

use strict;
use warnings;

use Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw(bosh credhub);

sub bosh { # bosh needs to point to itself, not its parent
	my $self = shift;
	return $self->{__bosh} ||= sub {
		my $self = shift;
		my $exodus_data = $self->exodus_data();
		my $bosh;
		if ($exodus_data->{url} && $exodus_data->{admin_password}) {
			$bosh = Service::BOSH::Director->from_exodus($self->env->name, exodus_data => $exodus_data);
		} else {
			$bosh = Service::BOSH::Director->from_alias($self->env->name);
		}
		$bosh->connect_and_validate();
		$bosh;
	}->($self);
}

sub credhub { # Like bosh, credhub needs to point to itself, not its parent
	my $self = shift;
	return $self->{__credhub} ||= sub {
		my ($self) = @_;
		require Service::Credhub;
		my $exodus = $self->exodus_data();
		my $credhub = Service::Credhub->new(
			$self->env->deployment_name,
			"/", # No root path
			$exodus->{credhub_url},
			$exodus->{credhub_username},
			$exodus->{credhub_password},
			sprintf("%s%s",$exodus->{ca_cert}||"",$exodus->{credhub_ca_cert}||"")
		);
		return $credhub;
	}->($self);
}

1
