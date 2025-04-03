package Genesis::Hook::Addon::BOSH::UploadStemcells v3.3.0;
use strict;
use warnings;

# Only needed for development
my $lib;
BEGIN {$lib = $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use lib $lib;

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info count_nouns/;
use Genesis::UI qw/prompt_for_boolean/;
use Genesis::Term qw/csprintf terminal_width/;
use Service::BOSH::Stemcell;

use Getopt::Long qw/GetOptionsFromArray/;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.20');
	return $obj;
}

sub cmd_details {
	return
		"Upload the appropriate BOSH stemcells. Supports the following options ".
		"and arguments:\n".
	# FIXME: Download and file options are not supported yet.
	#	"[[  #y{--dl}           >>download the stemcell file to the local machine ".
	#	                         "then upload it.  This may be necessary if the BOSH ".
	#	                         "director does not have direct access to the ".
	#	                         "internet.\n".
		"[[  #y{--fix}          >>upload the stemcell even if it is already uploaded.\n".
		"[[  #y{--os}           >>use the os <str> (defaults to ubuntu-jammy)\n".
		"[[  #y{--light}        >>use light stemcells instead of full ones\n".
		"[[  #y{--regular}      >>use regular stemcells instead of full ones\n".
		"[[  #y{--dry-run}      >>provide details on the listed or selected ".
		                         "stemcells, but don't upload them to the director.\n".
		"\n[[  #C{[os@]<version>} >>the version of the stemcell for the specified ".
		                         "(or default) OS.  Can be specified multiple ".
		                         "times.  If not specified, the user will be ".
		                         "presented with a list to choose from.\n".
	#	"[[  #C{<file>}         >>the path to a local stemcell file.  If specified, ".
	#	                         "this will be used inplace of the version.  Can ".
	#	                         "be specified multiple times.\n".
		"\n[[#Wku{Note:} >>The #y{--light} and #y{--regular} options are mutually ".
		"exclusive.  If neither are specified, the default is to use the value ".
		"specified under `bosh-configs.stemcells.type` in the environment file.\n"
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;
  my $bosh = $env->get_target_bosh({self => 1});

  # Default options
	my $type = $env->lookup('bosh-configs.stemcells.type');
  my %options = (
    os => 'ubuntu-jammy',
    versions => []
  );

	my @args = @{$self->{args}};
	GetOptionsFromArray(\@args, \%options,
		'os=s',
		'light',
		'regular',
		#'dl', # FIXME - this is not supported yet
		'fix',
		'dry-run',
	) or bail("Error parsing command line arguments");

	my @invalid_ops = grep { $_ =~ m#^-# } @args;
	if (@invalid_ops) {
		bail("Invalid options: %s", join(', ', @invalid_ops));
	}

	# Check for conflicting type options
	if ($options{light} && $options{regular}) {
		bail("The --light and --regular options are mutually exclusive");
	}
	$type = 'light' if $options{light};
	$type = 'regular' if $options{regular};

	# Present a list of versions to choose from if none are specified
	my @versions = @args;
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
			iaas => $self->env->iaas,
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
				my $v = $2;
				$available_for->{$os} = $bosh->available_stemcells(
					iaas => $self->env->iaas,
					os => $os,
					type => $type,
				) unless $available_for->{$os};
				$invalid->{$version} = "no versions found for $os" unless $available_for->{$os};
				if ($v eq 'latest') {
					push @stemcells, $available_for->{$os}->@[0];
					next;
				}
				my ($ss) = grep { $_->{version} eq $v } @{$available_for->{$os}};
				if ($ss) {
					push @stemcells, $ss;
				} else {
					$invalid->{$version} = "version not found for $os";
				}
			} else {
				# Must be a file
				my $file = $version;
				$file = "$ENV{GENESIS_CALLER_DIR}/$file" unless $file =~ m#^/|\.#;
				if (-f $file) {
					# TODO: create a file-based stemcell object
					# push @stemcells, $file;
					$invalid->{$version} = "file-based stemcells not supported yet";
				} else {
					$invalid->{$version} = "not a valid stemcell version nor a file";
				}
				next;
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

	# Upload the stemcells if any were found
	if (@stemcells) {
		$env->notify("uploading stemcells...");
		for my $stemcell (@stemcells) {
			info(
				"\n"."="x terminal_width()."\n".
				"%s\n".
				"-"x terminal_width() . "\n",
				$stemcell->description(csprintf(
					"#Mu{Uploading stemcell %s:}n",
					$stemcell->{name}
				)) =~ s/\s+$//r
			);
			$stemcell->upload($bosh,
				#download => $options{download}, # FIXME - this is not supported yet
				fix => $options{fix},
				dry_run => $options{dry_run},
			);
		}
		return 1;
	}
	$env->notify("#r{no stemcells found to upload}");
	return 0;
}

1;
