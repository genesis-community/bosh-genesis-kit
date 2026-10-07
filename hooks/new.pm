package Genesis::Hook::New::BOSH v4.1.0;

use strict;
use warnings;
use v5.20; # Genesis supports min perl v5.20.

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use parent qw(Genesis::Hook);

# Import required functions
use Genesis qw/trace bug bail warning info output/;
use Genesis::Term qw/in_controlling_terminal/;
use Genesis::UI qw/prompt_for_boolean new_prompt_for_choice prompt_for_line prompt_for_block/;
use Data::Dumper;
use File::Basename qw/basename dirname/;
use File::Path qw/mkpath/;

sub init {
  my ($class, %ops) = @_;
  my $obj = $class->SUPER::init(%ops);
	$obj->{files} = [];
	$obj->check_minimum_genesis_version('3.1.0');
  $obj->{features} = [];
  $obj->{config} = {
    kit => {
      name => $ENV{GENESIS_KIT_NAME},
      version => $ENV{GENESIS_KIT_VERSION},
      features => []
    },
    params => {}
  };
  return $obj;
}

sub perform {
  my ($self) = @_;

	bail("The 'new' hook is not supported in this Genesis version.\n");

  # Determine if this is a proto environment
  my $is_proto = $ENV{GENESIS_USE_CREATE_ENV} eq 'true';

  if ($is_proto) {
    push @{$self->{config}{kit}{features}}, 'proto';
  }

  # Get BOSH director environment if not proto
  if (!$is_proto) {
    $self->get_bosh_environment();
  }

  # Get static IP and network info
  $self->get_network_config($is_proto);

  # Get IaaS configuration
  $self->get_iaas_config($is_proto);

  # Get blobstore configuration
  $self->get_blobstore_config();

  # Get DNS configuration
  $self->get_dns_config();

  # Get access configuration
  $self->get_access_config();

  # Write YAML file
  $self->write_yaml_file($is_proto);

  # Offer environment editor
  system("offer_environment_editor");

  return $self->done();
}

sub get_bosh_environment {
  my ($self) = @_;

  my $bosh_env = '';
  my $inherited_bosh_env = '';
  my @default = ();

  if ($ENV{GENESIS_BOSH_ENVIRONMENT} && $ENV{GENESIS_BOSH_ENVIRONMENT} ne $ENV{GENESIS_ENVIRONMENT}) {
    @default = ('--default', $ENV{GENESIS_BOSH_ENVIRONMENT});
  } else {
    # Try to infer from ancestors
    my $path = $ENV{GENESIS_ENVIRONMENT};
    $path =~ s/-.*$//;

    my @segments = ();
    my $env_root = $ENV{GENESIS_ROOT} || '.';
    my $cwd = $ENV{PWD};

    chdir($env_root);
    while ($path) {
      if (-f "$path.yml") {
        push @segments, "$path.yml";
      }
      if ($path =~ /-/) {
        $path =~ s/-[^-]*$//; # Remove last segment
      } else {
        $path = '';
      }
    }

    if (@segments) {
      # Use spruce to extract ancestor bosh_env - shell equivalent not easily done in Perl
      # This is a simplification - the real logic might need system calls to spruce
      my $cmd = "spruce merge --skip-eval " . join(" ", @segments) . " | spruce json | jq -r '.genesis.bosh_env // \"\"'";
      my $ancestor_bosh_env = `$cmd`;
      chomp($ancestor_bosh_env);

      if ($ancestor_bosh_env) {
        @default = ('--default', "$ancestor_bosh_env (inherited)");
      }
    }

    chdir($cwd);
  }

  while (1) {
    $bosh_env = prompt_for_line(
      'What existing BOSH director environment is this BOSH director being deployed on?',
      @default
    );

    $ENV{GENESIS_USE_CREATE_ENV} = 0;
    $ENV{GENESIS_BOSH_ENVIRONMENT} = $bosh_env;

    if ($bosh_env =~ /\(inherited\)$/) {
      $bosh_env =~ s/ \(inherited\)$//;
      $inherited_bosh_env = 1;
    }

    $ENV{BOSH_ALIAS} = $bosh_env; # Sets up genesis_config_block

    if ($bosh_env && $bosh_env ne $ENV{GENESIS_ENVIRONMENT}) {
      last;
    }

    info("#R{[INVALID]} Target BOSH director environment must not be the same as this environment.\n");
  }

  $self->{config}{bosh_env} = $bosh_env;
  $self->{config}{inherited_bosh_env} = $inherited_bosh_env;
}

sub get_network_config {
  my ($self, $is_proto) = @_;

  my $ip = prompt_for_line(
    'What static IP do you want to deploy this BOSH director on?',
    '--validation', 'ip'
  );

  $self->{config}{params}{static_ip} = $ip;

  if ($is_proto) {
    my $proto_net = prompt_for_line(
      'What network should this BOSH director exist in (in CIDR notation)?'
    );

    my $proto_gw = prompt_for_line(
      'What default gateway (IP address) should this BOSH director use?',
      '--validation', 'ip'
    );

    my @proto_dns = prompt_for('multi-line',
      'What DNS servers should BOSH use?'
    );

    $self->{config}{params}{subnet_addr} = $proto_net;
    $self->{config}{params}{default_gateway} = $proto_gw;
    if (@proto_dns) {
      $self->{config}{params}{dns} = \@proto_dns;
    }
  }
}

sub get_iaas_config {
  my ($self, $is_proto) = @_;

  my $iaas = prompt_for_select(
    'What IaaS will this BOSH director orchestrate?',
    '-o', '[vsphere]   VMWare vSphere',
    '-o', '[aws]       Amazon Web Services',
    '-o', '[azure]     Microsoft Azure',
    '-o', '[google]    Google Cloud Platform',
    '-o', '[openstack] OpenStack',
    '-o', '[stackit]   STACKIT',
    '-o', '[warden]    BOSH Warden'
  );

  push @{$self->{config}{kit}{features}}, $iaas;
  $self->{config}{iaas} = $iaas;

  my $aws_iam_profile_name = '';

  if ($iaas eq 'aws') {
    $self->configure_aws($is_proto, \$aws_iam_profile_name);
  } elsif ($iaas eq 'vsphere') {
    $self->configure_vsphere($is_proto);
  } elsif ($iaas eq 'google') {
    $self->configure_google($is_proto);
  } elsif ($iaas eq 'azure') {
    $self->configure_azure($is_proto);
  } elsif ($iaas eq 'openstack') {
    $self->configure_openstack($is_proto);
  } elsif ($iaas eq 'stackit') {
    $self->configure_stackit($is_proto);
  }

  $self->{config}{aws_iam_profile_name} = $aws_iam_profile_name if $aws_iam_profile_name;
}

sub configure_aws {
  my ($self, $is_proto, $aws_iam_profile_name_ref) = @_;

  my $aws_region = prompt_for_line(
    'What AWS region would you like to deploy to?'
  );

  my $aws_auth_method = prompt_for_select(
    'How will this BOSH director authenticate to AWS?',
    '-o', '[access_key] Access/Secret Keypair',
    '-o', '[profile]    IAM Instance Profile'
  );

  if ($aws_auth_method eq 'access_key') {
    my $aws_access_key = prompt_for_line(
      'What is your AWS Access Key?',
      '--echo', '--secret-line'
    );

    my $aws_secret_key = prompt_for_line(
      'What is your AWS Secret Key?',
      '--secret-line'
    );

    # Store in vault
    my $secrets_base = $self->env->secrets_base;
    system("safe set --quiet \"${secrets_base}aws\" access_key=\"$aws_access_key\" secret_key=\"$aws_secret_key\"");
  } else {
    push @{$self->{config}{kit}{features}}, "iam-instance-profile";

    if ($is_proto) {
      $$aws_iam_profile_name_ref = prompt_for_line(
        'What AWS IAM instance profile should the Proto-BOSH VM have associated with it?'
      );
    }
  }

  my @aws_default_sgs = prompt_for('multi-line', '-m', 1,
    'What security groups should the all deployed VMs be placed in?'
  );

  $self->{config}{params}{aws_region} = $aws_region;
  $self->{config}{params}{aws_default_sgs} = \@aws_default_sgs;

  if ($is_proto) {
    my $aws_subnet = prompt_for_line(
      'What is the ID of the AWS subnet you want to deploy to?'
    );

    my @aws_bosh_sgs = prompt_for('multi-line', '-m', 1,
      'What security groups should the BOSH Director VM be in?'
    );

    $self->{config}{params}{aws_subnet_id} = $aws_subnet;
    $self->{config}{params}{aws_security_groups} = \@aws_bosh_sgs;

    if ($$aws_iam_profile_name_ref) {
      $self->{config}{params}{aws_proto_iam_instance_profile} = $$aws_iam_profile_name_ref;
    }
  }

  output("Before deploying, please be sure to import the keypair generated for you from\n".
    "Vault into AWS console.\n\n".
    "First run the following command to get the public key:\n\n".
    "  safe -T $ENV{GENESIS_TARGET_VAULT} get ${self->env->secrets_base}aws/ssh:public\n\n".
    "Then go to EC2 > Key Pairs > Import Key Pair and:\n\n".
    "  1. Type 'vcap\@$ENV{GENESIS_ENVIRONMENT}' in the 'Key pair name' input box\n".
    "  2. Paste the safe command output into the 'Public key contents' input box\n".
    "  3. Click 'Import' button\n\n".
    "Now you can SSH into VMs deployed by this director using the generated key.\n");
}

sub configure_vsphere {
  my ($self, $is_proto) = @_;

  # Check if parent environment has these values set
  my ($parent_vsphere_address, $parent_vsphere_user, $parent_vsphere_password) = ('', '', '');
  my ($parent_vsphere_datacenter, $parent_vsphere_cluster) = ('', '');
  my ($parent_vsphere_datastores_ephemeral, $parent_vsphere_datastores_persistent) = ('', '');

  if (!$is_proto) {
    if (system("safe get \"${ENV{GENESIS_EXODUS_MOUNT}}/$ENV{BOSH_ALIAS}/bosh:vault_base\" 2>/dev/null") == 0) {
      my $bosh_vault = `safe get "${ENV{GENESIS_EXODUS_MOUNT}}/$ENV{BOSH_ALIAS}/bosh:vault_base" 2>/dev/null`;
      chomp($bosh_vault);

      if (system("safe get \"$bosh_vault/vsphere\" 2>/dev/null") == 0) {
        my $vsphere_secrets = `safe get "$bosh_vault/vsphere" 2>/dev/null | spruce json`;

        if ($vsphere_secrets) {
          my $json = eval { decode_json($vsphere_secrets) };
          if ($json) {
            $parent_vsphere_address = $json->{address} || '';
            $parent_vsphere_user = $json->{user} || '';
            $parent_vsphere_password = $json->{password} || '';
          }
        }
      }
    }

    if (-f "$ENV{GENESIS_ROOT}/$ENV{BOSH_ALIAS}.yml") {
      my $json = `spruce json "$ENV{GENESIS_ROOT}/$ENV{BOSH_ALIAS}.yml" | jq -M`;
      if ($json) {
        my $parent_env_json = eval { decode_json($json) };
        if ($parent_env_json) {
          $parent_vsphere_cluster = $parent_env_json->{params}{vsphere_clusters}[0] || '';
          $parent_vsphere_datacenter = $parent_env_json->{params}{vsphere_datacenter} || '';

          if ($parent_env_json->{params}{vsphere_ephemeral_datastores}) {
            $parent_vsphere_datastores_ephemeral = join(' ', @{$parent_env_json->{params}{vsphere_ephemeral_datastores}});
          }

          if ($parent_env_json->{params}{vsphere_persistent_datastores}) {
            $parent_vsphere_datastores_persistent = join(' ', @{$parent_env_json->{params}{vsphere_persistent_datastores}});
          }
        }
      }
    }
  }

  my $vsphere_address = prompt_for_line(
    'What is the IP Address or Domain Name of your VMWare vCenter Server Appliance (:port optional)?',
    '--default', $parent_vsphere_address,
    '--validation', '/^((([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])|(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9]))(?::[0-9]+)?$/'
  );

  my $vsphere_user = prompt_for_line(
    'What username should BOSH use to authenticate with vCenter?',
    '--default', $parent_vsphere_user
  );

  my $use_parent_password = 'false';
  if ($parent_vsphere_password &&
    $parent_vsphere_address eq $vsphere_address &&
    $parent_vsphere_user eq $vsphere_user) {
    $use_parent_password = prompt_for_boolean(
      "Use the existing password for #M{$vsphere_user} at #C{$vsphere_address} from $ENV{BOSH_ALIAS} secrets?",
      '-i', '--default', 'true'
    );
  }

  if ($use_parent_password eq 'true') {
    system("safe --quiet set \"${self->env->secrets_base}vsphere\" password=\"$parent_vsphere_password\"");
  } else {
    my $vsphere_password = prompt_for_line(
      'What is the password for the vCenter user?',
      '--secret-line'
    );
    system("safe --quiet set \"${self->env->secrets_base}vsphere\" password=\"$vsphere_password\"");
  }

  system("safe --quiet set \"${self->env->secrets_base}vsphere\" user=\"$vsphere_user\" address=\"$vsphere_address\"");

  my $vsphere_dc = prompt_for_line(
    'What vCenter data center do you want to BOSH to deploy to?',
    '--default', $parent_vsphere_datacenter
  );

  my $vsphere_cluster = prompt_for_line(
    'What vCenter cluster do you want BOSH to deploy to?',
    '--default', $parent_vsphere_cluster
  );

  my $vsphere_resource_pool = prompt_for_line(
    'What vCenter resource pool (if any) do you want BOSH to deploy to?',
    '--default', 'none'
  );

  my $use_parental_datastores = 'false';
  if ($parent_vsphere_datastores_ephemeral || $parent_vsphere_datastores_persistent) {
    info(
      "Parent BOSH environment '$ENV{BOSH_ALIAS}' defines the following datastores:\n\n".
      "Persistent:\n".
      ($parent_vsphere_datastores_persistent ? "  - $parent_vsphere_datastores_persistent\n" : "  #i{none}\n").
      "\n".
      "Ephemeral: \n".
      ($parent_vsphere_datastores_ephemeral ? "  - $parent_vsphere_datastores_ephemeral\n" : "  #i{none}\n")
    );

    $use_parental_datastores = prompt_for_boolean(
      "Use the same persistent and ephemeral data stores as $ENV{BOSH_ALIAS} ?",
      '-i', '--default', 'true'
    );
  }

  my (@vsphere_ephemerals, @vsphere_persistents);

  if ($use_parental_datastores eq 'true') {
    @vsphere_ephemerals = split(/\s+/, $parent_vsphere_datastores_ephemeral);
    @vsphere_persistents = split(/\s+/, $parent_vsphere_datastores_persistent);
  } else {
    @vsphere_ephemerals = prompt_for('multi-line', '-m', 1,
      'What data stores do you wish to use for ephemeral (OS) disks?'
    );

    my $same_datastores = prompt_for_boolean(
      'Do you wish to use these same data stores for persistent (data) disks?'
    );

    if ($same_datastores eq 'false') {
      @vsphere_persistents = prompt_for('multi-line', '-m', 1,
        'What data stores do you wish to use for persistent (data) disks?'
      );
    } else {
      @vsphere_persistents = @vsphere_ephemerals;
    }
  }

  $self->{config}{params}{vsphere_datacenter} = $vsphere_dc;
  $self->{config}{params}{vsphere_clusters} = [];

  if ($vsphere_resource_pool eq 'none') {
    push @{$self->{config}{params}{vsphere_clusters}}, $vsphere_cluster;
  } else {
    push @{$self->{config}{params}{vsphere_clusters}}, {
      cluster => $vsphere_cluster,
      resource_pool => $vsphere_resource_pool
    };
  }

  $self->{config}{params}{vsphere_ephemeral_datastores} = \@vsphere_ephemerals;
  $self->{config}{params}{vsphere_persistent_datastores} = \@vsphere_persistents;

  if ($is_proto) {
    my $vsphere_net = prompt_for_line(
      'What is the name of the VM network in vCenter to deploy BOSH to?'
    );

    $self->{config}{params}{vsphere_network} = $vsphere_net;
  }
}

sub configure_google {
  my ($self, $is_proto) = @_;

  my $google_project_id = prompt_for_line(
    'What is your GCP project ID?'
  );

  my $google_json_key = prompt_for_block(
    'What are your GCP credentials (generally supplied as a JSON block)?'
  );

  system("safe set --quiet \"${self->env->secrets_base}google\" json_key=\"$google_json_key\"");

  $self->{config}{params}{google_project} = $google_project_id;

  if ($is_proto) {
    my $google_net = prompt_for_line(
      'What is your GCP network name?'
    );

    my $google_subnet = prompt_for_line(
      'What is your GCP subnetwork name?'
    );

    my $google_azs = prompt_for_line(
      'What availability zone do you want the BOSH VM to reside in?'
    );

    my @google_tags = prompt_for('multi-line',
      'What tags would you like to be set on the BOSH VM?'
    );

    $self->{config}{params}{google_network_name} = $google_net;
    $self->{config}{params}{google_subnetwork_name} = $google_subnet;
    $self->{config}{params}{google_availability_zone} = $google_azs;
    $self->{config}{params}{google_tags} = \@google_tags;
  }
}

sub configure_azure {
  my ($self, $is_proto) = @_;

  my $azure_client_id = prompt_for_line(
    'What is your Azure Client ID?'
  );

  my $azure_client_secret = prompt_for_line(
    'What is your Azure Client Secret?',
    '--secret-line'
  );

  my $azure_tenant_id = prompt_for_line(
    'What is your Azure Tenant ID?'
  );

  my $azure_subscription_id = prompt_for_line(
    'What is your Azure Subscription ID?'
  );

  my $azure_resource_group = prompt_for_line(
    'What Azure Resource Group will BOSH be deploying VMs into?'
  );

  system("safe --quiet set \"${self->env->secrets_base}azure\" client_id=\"$azure_client_id\" client_secret=\"$azure_client_secret\" tenant_id=\"$azure_tenant_id\" subscription_id=\"$azure_subscription_id\"");

  my $azure_default_sg = prompt_for_line(
    'What security group should be used as the BOSH default security group?'
  );

  $self->{config}{params}{azure_resource_group} = $azure_resource_group;
  $self->{config}{params}{azure_default_sg} = $azure_default_sg;

  if ($is_proto) {
    my $azure_vnet = prompt_for_line(
      'What is the name of your Azure Virtual Network?'
    );

    my $azure_subnet_name = prompt_for_line(
      'What is the name of the Azure subnet that the BOSH will be placed in?'
    );

    $self->{config}{params}{azure_virtual_network} = $azure_vnet;
    $self->{config}{params}{azure_subnet_name} = $azure_subnet_name;
  }
}

sub configure_openstack {
  my ($self, $is_proto) = @_;

  my $openstack_auth_url = prompt_for_line(
    'What is the Auth URL of your OpenStack cluster?'
  );

  my $openstack_user = prompt_for_line(
    'What username will be used to authenticate with OpenStack?'
  );

  my $openstack_password = prompt_for_line(
    'What password will be used to authenticate with OpenStack?',
    '--secret-line'
  );

  my $openstack_domain = prompt_for_line(
    'What OpenStack Domain will BOSH be deployed in?'
  );

  my $openstack_project = prompt_for_line(
    'What OpenStack Project will BOSH be deployed in?'
  );

  system("safe set --quiet \"${self->env->secrets_base}openstack/creds\" username=\"$openstack_user\" password=\"$openstack_password\" domain=\"$openstack_domain\" project=\"$openstack_project\"");

  my $openstack_region = prompt_for_line(
    'What OpenStack Region is BOSH being deployed to?'
  );

  my $openstack_ssh_key = prompt_for_line(
    'What is the name of the OpenStack SSH key that should be used to enable SSH access to BOSH-deployed VMs?'
  );

  my @openstack_default_sgs = prompt_for('multi-line',
    'What default security groups should be applied to VMs created by BOSH?'
  );

  $self->{config}{params}{openstack_auth_url} = $openstack_auth_url;
  $self->{config}{params}{openstack_region} = $openstack_region;
  $self->{config}{params}{openstack_ssh_key} = $openstack_ssh_key;
  $self->{config}{params}{openstack_default_security_groups} = \@openstack_default_sgs;

  if ($is_proto) {
    my $openstack_network_id = prompt_for_line(
      'What is the UUID of the OpenStack network that BOSH will be placed in?'
    );

    my $openstack_flavor = prompt_for_line(
      'What OpenStack flavor (instance type) should the BOSH VM use?'
    );

    my $openstack_az = prompt_for_line(
      'What AZ will the BOSH Director be placed in?'
    );

    $self->{config}{params}{openstack_network_id} = $openstack_network_id;
    $self->{config}{params}{openstack_flavor} = $openstack_flavor;
    $self->{config}{params}{openstack_az} = $openstack_az;
  }
}

sub configure_stackit {
  my ($self, $is_proto) = @_;

  my $stackit_auth_url = prompt_for_line(
    'What is the Auth URL of your STACKIT cluster?'
  );

  my $stackit_user = prompt_for_line(
    'What username will be used to authenticate with STACKIT?'
  );

  my $stackit_password = prompt_for_line(
    'What password will be used to authenticate with STACKIT?',
    '--secret-line'
  );

  my $stackit_domain = prompt_for_line(
    'What STACKIT Domain will BOSH be deployed in?'
  );

  my $stackit_project = prompt_for_line(
    'What STACKIT Project will BOSH be deployed in?'
  );

  system("safe set --quiet \"${self->env->secrets_base}stackit/creds\" username=\"$stackit_user\" password=\"$stackit_password\" domain=\"$stackit_domain\" project=\"$stackit_project\"");

  my $stackit_region = prompt_for_line(
    'What STACKIT Region is BOSH being deployed to?'
  );

  my $stackit_ssh_key = prompt_for_line(
    'What is the name of the STACKIT SSH key that should be used to enable SSH access to BOSH-deployed VMs?'
  );

  my @stackit_default_sgs = prompt_for('multi-line',
    'What default security groups should be applied to VMs created by BOSH?'
  );

  $self->{config}{params}{stackit_auth_url} = $stackit_auth_url;
  $self->{config}{params}{stackit_region} = $stackit_region;
  $self->{config}{params}{stackit_ssh_key} = $stackit_ssh_key;
  $self->{config}{params}{stackit_default_security_groups} = \@stackit_default_sgs;

  if ($is_proto) {
    my $stackit_network_id = prompt_for_line(
      'What is the UUID of the STACKIT network that BOSH will be placed in?'
    );

    my $stackit_subnet_id = prompt_for_line(
      'What is the UUID of the STACKIT subnet that BOSH will be placed in?'
    );

    my $stackit_flavor = prompt_for_line(
      'What STACKIT flavor (instance type) should the BOSH VM use?'
    );

    my $stackit_az = prompt_for_line(
      'What AZ will the BOSH Director be placed in?'
    );

    $self->{config}{params}{stackit_network_id} = $stackit_network_id;
    $self->{config}{params}{stackit_subnet_id} = $stackit_subnet_id;
    $self->{config}{params}{stackit_flavor} = $stackit_flavor;
    $self->{config}{params}{stackit_az} = $stackit_az;
  }
}

sub get_blobstore_config {
  my ($self) = @_;

  my $blobstore = prompt_for_select(
    'What Blobstore do you want to use?',
    '-o', '[internal] Create a local blobstore on the BOSH director VM',
    '-o', '[s3]       Use an existing AWS S3 Blobstore',
    '--default', "internal"
  );

  if ($blobstore eq 's3') {
    push @{$self->{config}{kit}{features}}, 's3-blobstore';

    my $blobstore_s3_bucket = prompt_for_line(
      'What is the name of the S3 Bucket?'
    );

    my $blobstore_s3_region = prompt_for_line(
      'What region contains the \'' . $blobstore_s3_bucket . '\' S3 Bucket?'
    );

    my $blobstore_s3_auth_method = 'access_key';
    if ($self->{config}{iaas} eq 'aws') {
      $blobstore_s3_auth_method = prompt_for_select(
        'How will this BOSH director authenticate to S3?',
        '-o', '[access_key] Access/Secret Keypair',
        '-o', '[profile]    IAM Instance Profile',
        '--default', $self->{config}{aws_auth_method} || 'access_key'
      );
    }

    if ($blobstore_s3_auth_method eq 'access_key') {
      my $access_key = prompt_for_line(
        "What is your AWS Access Key for the '$blobstore_s3_bucket' S3 Bucket?",
        '--echo', '--secret-line'
      );

      my $secret_key = prompt_for_line(
        "What is your AWS Secret Key for the '$blobstore_s3_bucket' S3 Bucket?",
        '--secret-line'
      );

      system("safe set --quiet \"${self->env->secrets_base}blobstore/s3\" access_key=\"$access_key\" secret_key=\"$secret_key\"");
    } else {
      push @{$self->{config}{kit}{features}}, 's3-blobstore-iam-instance-profile';

      if ($self->{config}{is_proto} && !$self->{config}{aws_iam_profile_name}) {
        $self->{config}{aws_iam_profile_name} = prompt_for_line(
          'What AWS IAM instance profile should the Proto-BOSH VM have associated with it?'
        );
      }
    }

    $self->{config}{params}{s3_blobstore_bucket} = $blobstore_s3_bucket;
    $self->{config}{params}{s3_blobstore_region} = $blobstore_s3_region;
  }
}

sub get_dns_config {
  my ($self) = @_;

  my $dnshealthcheck = prompt_for_boolean(
    'Do you want to enable BOSH DNS healthcheck?',
    '-i', '--default', 'true'
  );

  if ($dnshealthcheck eq 'true') {
    push @{$self->{config}{kit}{features}}, 'bosh-dns-healthcheck';
  }

  my $dnscache = prompt_for_boolean(
    'Do you want to enable BOSH DNS caching?',
    '-i', '--default', 'true'
  );

  $self->{config}{params}{dns_cache} = $dnscache;
}

sub get_access_config {
  my ($self) = @_;

  info(
    "\n".
    "The \`netop' user is a local administrator account configured with\n".
    "a 4096-bit RSA SSH key for authentication.  It can be used to perform\n".
    "out-of-band, remote management of BOSH VMs when BOSH is misbehaving.\n\n"
  );

  my $do_netop = prompt_for_boolean(
    "Enable the netop account? ",
    '-i', '--default', 'true'
  );

  if ($do_netop eq 'true') {
    push @{$self->{config}{kit}{features}}, 'netop-access';
  }

  info(
    "\n".
    "The \`sysop' user is a local administrator account configured with\n".
    "a randomized password, for console-based authentication.  This can be\n".
    "handy in vSphere environments when network-based authentication breaks.\n\n"
  );

  my $do_sysop = prompt_for_boolean(
    "Enable the sysop account? ",
    '-i', '--default', 'true'
  );

  if ($do_sysop eq 'true') {
    push @{$self->{config}{kit}{features}}, 'sysop-access';
  }
}

sub write_yaml_file {
  my ($self, $is_proto) = @_;

  my $output = '';

  # Kit section
  $output .= "kit:\n";
  $output .= "  name:    $ENV{GENESIS_KIT_NAME}\n";
  $output .= "  version: $ENV{GENESIS_KIT_VERSION}\n";
  $output .= "  features:\n";
  $output .= "    - $self->{config}{iaas}\n";

  if ($is_proto) {
    $output .= "    - proto\n";
  }

  foreach my $feature (@{$self->{config}{kit}{features}}) {
    $output .= "    - $feature\n";
  }

  # Genesis config block
  $output .= "\n";

  if ($self->{config}{inherited_bosh_env}) {
    $ENV{BOSH_ALIAS} = $ENV{GENESIS_ENVIRONMENT}; # Trick genesis_config_block
  }

  # Add genesis block through system call to maintain compatibility
  my $genesis_block = `genesis_config_block 2>/dev/null`;
  $output .= $genesis_block;

  # Params section
  $output .= "\nparams:\n";

  if ($is_proto) {
    $output .= "  # These properties definte the host-level networking for a proto-BOSH.\n";
    $output .= "  # Environmental BOSHes can depend on their parent BOSH cloud-config,\n";
    $output .= "  # but for proto- environments, we have to specify these.\n";
    $output .= "  #\n";
    $output .= "  static_ip:       $self->{config}{params}{static_ip}\n";
    $output .= "  subnet_addr:     $self->{config}{params}{subnet_addr}\n";
    $output .= "  default_gateway: $self->{config}{params}{default_gateway}\n";

    if ($self->{config}{params}{dns} && @{$self->{config}{params}{dns}}) {
      $output .= "  dns:\n";
      foreach my $dns (@{$self->{config}{params}{dns}}) {
        $output .= "    - $dns\n";
      }
    }
  } else {
    $output .= "  # These parameters are all that we need to specify for an Environment\n";
    $output .= "  # BOSH, since networking and VM type configuration comes from that cloud-config\n";
    $output .= "  #\n";
    $output .= "  static_ip: $self->{config}{params}{static_ip}\n";
  }

  $output .= "\n";

  # IaaS specific configuration
  if ($self->{config}{iaas} eq 'aws') {
    $output .= "  # BOSH on AWS needs to know what region to deploy to, and what\n";
    $output .= "  # default security groups to apply to all VMs by default.\n";
    $output .= "  #\n";
    $output .= "  # AWS credentials are stored in the Vault at\n";
    $output .= "  #   ${self->env->secrets_base}aws\n";
    $output .= "  #\n";
    $output .= "  aws_region: $self->{config}{params}{aws_region}\n";
    $output .= "  aws_default_sgs:\n";

    foreach my $sg (@{$self->{config}{params}{aws_default_sgs}}) {
      $output .= "    - $sg\n";
    }

    $output .= "\n";

    if ($is_proto) {
      $output .= "  # The following configuration is only necessary for proto-BOSH\n";
      $output .= "  # deployments, since environment BOSHes will derive their networking\n";
      $output .= "  # and VM/AMI configuration from their parent BOSH cloud-config.\n";
      $output .= "  #\n";
      $output .= "  aws_subnet_id: $self->{config}{params}{aws_subnet_id}\n";
      $output .= "  aws_security_groups:\n";

      foreach my $sg (@{$self->{config}{params}{aws_security_groups}}) {
        $output .= "    - $sg\n";
      }

      $output .= "\n";

      if ($self->{config}{params}{aws_proto_iam_instance_profile}) {
        $output .= "  aws_proto_iam_instance_profile: $self->{config}{params}{aws_proto_iam_instance_profile}\n";
      }
    }
  } elsif ($self->{config}{iaas} eq 'vsphere') {
    $output .= "  # BOSH on vSphere (vCenter) needs to know which vCenter data\n";
    $output .= "  # center and cluster to deploy to by default.\n";
    $output .= "  #\n";
    $output .= "  # vCenter credentials are stored in the Vault at\n";
    $output .= "  #   ${self->env->secrets_base}vsphere\n";
    $output .= "  #\n";
    $output .= "  vsphere_datacenter: $self->{config}{params}{vsphere_datacenter}\n";
    $output .= "  vsphere_clusters:\n";

    foreach my $cluster (@{$self->{config}{params}{vsphere_clusters}}) {
      if (ref($cluster) eq 'HASH') {
        $output .= "    - $cluster->{cluster}:\n";
        $output .= "        resource_pool: $cluster->{resource_pool}\n";
      } else {
        $output .= "    - $cluster\n";
      }
    }

    $output .= "\n";
    $output .= "  # BOSH will store ephemeral disks, which house the operating system,\n";
    $output .= "  # and temporary work areas, on any of theses data stores\n";
    $output .= "  #\n";
    $output .= "  vsphere_ephemeral_datastores:\n";

    foreach my $ds (@{$self->{config}{params}{vsphere_ephemeral_datastores}}) {
      $output .= "    - $ds\n";
    }

    $output .= "\n";
    $output .= "  # BOSH will store persistent disks, which contain the important\n";
    $output .= "  # data of your various deployments (databases, blobstores, etc.)\n";
    $output .= "  # on any of theses data stores\n";
    $output .= "  #\n";
    $output .= "  vsphere_persistent_datastores:\n";

    foreach my $ds (@{$self->{config}{params}{vsphere_persistent_datastores}}) {
      $output .= "    - $ds\n";
    }

    $output .= "\n";

    if ($is_proto) {
      $output .= "  # The following configuration is only necessary for proto-BOSH\n";
      $output .= "  # deployments, since environment BOSHes will derive their networking\n";
      $output .= "  # configuration from their parent BOSH cloud-config.\n";
      $output .= "  #\n";
      $output .= "  vsphere_network:    $self->{config}{params}{vsphere_network}\n";
      $output .= "\n";
    }
  } elsif ($self->{config}{iaas} eq 'google') {
    $output .= "  # BOSH on GCP needs to know what project to deploy to.\n";
    $output .= "  #\n";
    $output .= "  # GCP credentials are stored in the Vault at\n";
    $output .= "  #   ${self->env->secrets_base}google\n";
    $output .= "  #\n";
    $output .= "  google_project: $self->{config}{params}{google_project}\n";
    $output .= "\n";

    if ($is_proto) {
      $output .= "  # The following configuration is only necessary for proto-BOSH\n";
      $output .= "  # deployments, since environment BOSHes will derive their networking\n";
      $output .= "  # tags, and zone configuration from their parent BOSH cloud-config.\n";
      $output .= "  #\n";
      $output .= "  google_network_name:      $self->{config}{params}{google_network_name}\n";
      $output .= "  google_subnetwork_name:   $self->{config}{params}{google_subnetwork_name}\n";
      $output .= "  google_availability_zone: $self->{config}{params}{google_availability_zone}\n";
      $output .= "  google_tags:\n";

      foreach my $tag (@{$self->{config}{params}{google_tags}}) {
        $output .= "    - $tag\n";
      }

      $output .= "\n";
    }
  } elsif ($self->{config}{iaas} eq 'azure') {
    $output .= "  # BOSH on Azure needs to know what resource groups to use when\n";
    $output .= "  # deploying VMs, as well as what default security group to apply\n";
    $output .= "  # to VMs that do not otherwise specify them.\n";
    $output .= "  #\n";
    $output .= "  # Azure credentials are stored in the Vault at\n";
    $output .= "  #   ${self->env->secrets_base}azure\n";
    $output .= "  #\n";
    $output .= "  azure_resource_group: $self->{config}{params}{azure_resource_group}\n";
    $output .= "  azure_default_sg:     $self->{config}{params}{azure_default_sg}\n";
    $output .= "\n";

    if ($is_proto) {
      $output .= "  # The following configuration is only necessary for proto-BOSH\n";
      $output .= "  # deployments, since environment BOSHes will derive their networking\n";
      $output .= "  # and resource groups from their parent BOSH cloud-config.\n";
      $output .= "  #\n";
      $output .= "  azure_virtual_network: $self->{config}{params}{azure_virtual_network}\n";
      $output .= "  azure_subnet_name:     $self->{config}{params}{azure_subnet_name}\n";
      $output .= "\n";
    }
  } elsif ($self->{config}{iaas} eq 'openstack') {
    $output .= "  # BOSH on Openstack needs to know where the OpenStack API lives,\n";
    $output .= "  # what domain / project to use for deploying VMs, as well as what\n";
    $output .= "  # default security group to apply to all deployed VMs, and what\n";
    $output .= "  # named SSH key governs access to those VMs\n";
    $output .= "  #\n";
    $output .= "  # Openstack credentials are stored in the Vault at\n";
    $output .= "  #   ${self->env->secrets_base}openstack/creds\n";
    $output .= "  #\n";
    $output .= "  openstack_auth_url: $self->{config}{params}{openstack_auth_url}\n";
    $output .= "  openstack_region:   $self->{config}{params}{openstack_region}\n";
    $output .= "  openstack_ssh_key:  $self->{config}{params}{openstack_ssh_key}\n";
    $output .= "  openstack_default_security_groups:\n";

    foreach my $sg (@{$self->{config}{params}{openstack_default_security_groups}}) {
      $output .= "    - $sg\n";
    }

    $output .= "\n";

    if ($is_proto) {
      $output .= "  # The following configuration is only necessary for proto-BOSH\n";
      $output .= "  # deployments, since environment BOSHes will derive their networking\n";
      $output .= "  # flavor, and availability zones from their parent BOSH cloud-config.\n";
      $output .= "  #\n";
      $output .= "  openstack_network_id: $self->{config}{params}{openstack_network_id}\n";
      $output .= "  openstack_flavor:     $self->{config}{params}{openstack_flavor}\n";
      $output .= "  openstack_az:         $self->{config}{params}{openstack_az}\n";
      $output .= "\n";
    }
  } elsif ($self->{config}{iaas} eq 'stackit') {
    $output .= "  # BOSH on STACKIT needs to know where the STACKIT API lives,\n";
    $output .= "  # what domain / project to use for deploying VMs, as well as what\n";
    $output .= "  # default security group to apply to all deployed VMs, and what\n";
    $output .= "  # named SSH key governs access to those VMs\n";
    $output .= "  #\n";
    $output .= "  # STACKIT credentials are stored in the Vault at\n";
    $output .= "  #   ${self->env->secrets_base}stackit/creds\n";
    $output .= "  #\n";
    $output .= "  stackit_auth_url: $self->{config}{params}{stackit_auth_url}\n";
    $output .= "  stackit_region:   $self->{config}{params}{stackit_region}\n";
    $output .= "  stackit_ssh_key:  $self->{config}{params}{stackit_ssh_key}\n";
    $output .= "  stackit_default_security_groups:\n";

    foreach my $sg (@{$self->{config}{params}{stackit_default_security_groups}}) {
      $output .= "    - $sg\n";
    }

    $output .= "\n";

    if ($is_proto) {
      $output .= "  # The following configuration is only necessary for proto-BOSH\n";
      $output .= "  # deployments, since environment BOSHes will derive their networking\n";
      $output .= "  # flavor, and availability zones from their parent BOSH cloud-config.\n";
      $output .= "  #\n";
      $output .= "  stackit_network_id: $self->{config}{params}{stackit_network_id}\n";
      $output .= "  stackit_subnet_id: $self->{config}{params}{stackit_subnet_id}\n";
      $output .= "  stackit_flavor:     $self->{config}{params}{stackit_flavor}\n";
      $output .= "  stackit_az:         $self->{config}{params}{stackit_az}\n";
      $output .= "\n";
    }
  }

  # S3 blobstore configuration
  if ($self->{config}{params}{s3_blobstore_bucket}) {
    $output .= "  # External S3 Blobstore Configuration\n";
    $output .= "  s3_blobstore_bucket: $self->{config}{params}{s3_blobstore_bucket}\n";
    $output .= "  s3_blobstore_region: $self->{config}{params}{s3_blobstore_region}\n";
    $output .= "\n";
  }

  # DNS caching
  if ($self->{config}{params}{dns_cache}) {
    $output .= "  # DNS Caching (for runtime config)\n";
    $output .= "  dns_cache: $self->{config}{params}{dns_cache}\n";
    $output .= "\n";
  }

  # Write the final YAML file
  my $file_path = "$ENV{GENESIS_ROOT}/$ENV{GENESIS_ENVIRONMENT}.yml";

  # Create directory if it doesn't exist
  my $dir = dirname($file_path);
  mkpath($dir) unless -d $dir;

  # Write the file
  open(my $fh, '>', $file_path) or bail("Cannot write to $file_path: $!");
  print $fh $output;
  close($fh);

  return 1;
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
