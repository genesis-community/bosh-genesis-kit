package Genesis::Hook::Addon::BOSH::DownloadStemcells v4.0.1;

use strict;
use warnings;
use v5.20; # Genesis supports min perl v5.20.

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

# Parent class inheritance
# TODO: Question: Which one do we need???
#use parent qw(Genesis::Hook);
use parent qw(Genesis::Hook::Addon);

# Import required functions
use Genesis qw/bail info count_nouns run/;
use Genesis::UI qw/prompt_for_boolean/;
use Genesis::Term qw/csprintf terminal_width/;
use Service::BOSH::Stemcell;

use JSON::PP;

sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->check_minimum_genesis_version('3.1.0-rc.20');
	$obj->{files} = [];
  return $obj;
}

sub cmd_details {
  return
  "Download BOSH stemcells to a local directory. Supports the following options ".
  "and arguments:\n".
  "[[  #y{--dir} <path>   >>directory to download stemcells to (defaults to current directory)\n".
  "[[  #y{--os} <str>     >>use the os <str> (defaults to ubuntu-jammy)\n".
  "[[  #y{--light}        >>use light stemcells instead of full ones\n".
  "[[  #y{--regular}      >>use regular stemcells instead of full ones\n".
  "[[  #y{--dry-run}      >>provide details on the listed or selected ".
  "stemcells, but don't download them.\n".
  "\n[[  #C{[os@]<version>} >>the version of the stemcell for the specified ".
  "(or default) OS. Can be specified multiple ".
  "times. If not specified, the user will be ".
  "presented with a list to choose from.\n".
  "\n[[#Wku{Note:} >>The #y{--light} and #y{--regular} options are mutually ".
  "exclusive. If neither are specified, the default is to use the value ".
  "specified under `bosh-configs.stemcells.type` in the environment file.\n"
}

# Helper method to construct stemcell download URL
sub get_stemcell_url {
  my ($self, $stemcell) = @_;

  # Try to use built-in method if available
  if ($stemcell->can('download_url')) {
    return $stemcell->download_url();
  }

  # Otherwise construct URL based on stemcell properties
  my $url_base = "https://bosh.io/d/stemcells";
  my $stem_name = $stemcell->{name};
  my $version = $stemcell->{version};
  my $iaas = $stemcell->{iaas};
  my $is_light = $stemcell->{light} || 0;

  # Construct URL based on stemcell information
  my $url;
  if ($is_light) {
    $url = "$url_base/light-$stem_name-$version-$iaas.tgz";
  } else {
    $url = "$url_base/$stem_name-$version-$iaas.tgz";
  }

  return $url;
}

# Helper method to generate a filename for the stemcell
sub get_stemcell_filename {
  my ($self, $stemcell) = @_;

  my $stem_name = $stemcell->{name};
  my $version = $stemcell->{version};
  my $iaas = $stemcell->{iaas};
  my $is_light = $stemcell->{light} || 0;

  if ($is_light) {
    return "light-$stem_name-$version-$iaas.tgz";
  } else {
    return "$stem_name-$version-$iaas.tgz";
  }
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;
  my $bosh = $env->get_target_bosh({self => 1});

  # Parse options
  my %options = $self->parse_options([
      'dir=s',
      'os=s',
      'light',
      'regular',
      'dry-run',
    ],
    os => 'ubuntu-jammy',
    dir => '.',
  );

  # Check for conflicting type options
  if ($options{light} && $options{regular}) {
    bail("The --light and --regular options are mutually exclusive");
  }

  my $type = $env->lookup('bosh-configs.stemcells.type');
  $type = 'light' if $options{light};
  $type = 'regular' if $options{regular};

  # Ensure the download directory exists
  if (! -d $options{dir}) {
    if (-e $options{dir}) {
      bail("Specified download directory '%s' exists but is not a directory", $options{dir});
    }

    if ($options{'dry-run'}) {
      info("Would create directory: %s", $options{dir});
    } else {
      info("Creating download directory: %s", $options{dir});
      mkdir($options{dir}) or bail("Failed to create directory '%s': %s", $options{dir}, $!);
    }
  }

  # Present a list of versions to choose from if none are specified
  my @versions = @{$self->{args}};
  my @stemcells = ();
  if (@versions == 0) {
    my $again = 1;
    $env->notify({pending => 1},
      "determining available %s%s stemcells for %s VMs...",
      $type ? "$type " : '',
      $options{os},
      $env->iaas
    );
    my @available = $bosh->available_stemcells(
      iaas => ($self->env->iaas eq "stackit" ? "openstack" : $self->env->iaas),
      os => $options{os},
      type => $type,
    );
    info(" #%s{found %s}", scalar(@available) ? 'g':'r', count_nouns(scalar(@available), 'stemcell'));
    if (!@available) {
      bail("No available %s %s stemcells found for %s VMs", $type, $options{os}, $self->env->iaas);
    }

    while ($again) {
      my $selected = Service::BOSH::Stemcell->select_stemcell(
        stemcells => \@available,
        type => $type
      );
      if ($selected) {
        push @stemcells, $selected;
        $again = prompt_for_boolean(
          "\nDo you want to select another stemcell? [y|n] ",
          0
        );
      } else {
        $again = 0;
      }
    }
  } else {
    # Check if the versions are valid
    my $available_for = {};
    my $invalid = {};
    $env->notify({pending => 1}, "validating stemcell versions...");
    for my $version (@versions) {
      info({pending => 1}, ".");
      if ($version =~ m#^(?:(.*@))?(latest|\d+.\d+)$#) {
        my $os = $1 || $options{os};
        $os =~ s/@$//; # Remove trailing @ if present
        my $v = $2;
        $available_for->{$os} = $bosh->available_stemcells(
          iaas => ($self->env->iaas eq "stackit" ? "openstack" : $self->env->iaas),
          os => $os,
          type => $type,
        ) unless exists $available_for->{$os};

        $invalid->{$version} = "no versions found for $os"
        unless $available_for->{$os} && @{$available_for->{$os}};

        if ($v eq 'latest') {
          push @stemcells, $available_for->{$os}->[0] if $available_for->{$os};
          next;
        }

        my ($ss) = grep { $_->{version} eq $v } @{$available_for->{$os} || []};
        if ($ss) {
          push @stemcells, $ss;
        } else {
          $invalid->{$version} = "version not found for $os";
        }
      } else {
        $invalid->{$version} = "not a valid stemcell version";
      }
    }
    if (keys %$invalid) {
      info("#r{failed}");
      my $msg = "\nThe following stemcell versions are invalid:\n";
      for my $version (keys %$invalid) {
        $msg .= sprintf("  - %s: %s\n", $version, $invalid->{$version});
      }
      bail($msg);
    }
  }
  info("#g{done}");

  # Download the stemcells if any were found
  if (@stemcells) {
    $env->notify("downloading stemcells...");
    for my $stemcell (@stemcells) {
      info(
        "\n"."="x terminal_width()."\n".
        "%s\n".
        "-"x terminal_width() . "\n",
        $stemcell->description(csprintf(
            "#Mu{Downloading stemcell %s:}n",
            $stemcell->{name}
          )) =~ s/\s+$//r
      );

      # Get the download URL for the stemcell
      my $url = $self->get_stemcell_url($stemcell);
      unless ($url) {
        bail("Unable to determine download URL for stemcell: %s", $stemcell->{name});
      }

      my $filename = $self->get_stemcell_filename($stemcell);
      my $target_path = "$options{dir}/$filename";

      if ($options{'dry-run'}) {
        info("Would download stemcell from: %s", $url);
        info("Would save to: %s", $target_path);
      } else {
        info("Downloading stemcell from: %s", $url);
        info("Saving to: %s", $target_path);

        # Download the stemcell using curl with progress indicator
        my ($out, $rc, $err) = run('curl -L --progress-bar "%s" -o "%s"', $url, $target_path);

        if ($rc != 0) {
          bail("Failed to download stemcell: %s", $err || "Unknown error");
        }

        # Verify the download
        if (-f $target_path) {
          my $size = -s $target_path;
          my $size_mb = sprintf("%.1f MB", $size / (1024 * 1024));
          info("#g{Successfully downloaded stemcell to: %s (%s)}", $target_path, $size_mb);
        } else {
          bail("Download appeared to succeed, but file not found at: %s", $target_path);
        }
      }
    }

    $env->notify(success => "downloaded %s to %s",
      count_nouns(scalar(@stemcells), 'stemcell'),
      $options{dir}
    );
    return $self->done(1);

  }
  $env->notify("#r{no stemcells found to download}");

  return $self->done();
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
