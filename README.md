BOSH Genesis Kit
==================

This is a Genesis Kit for deploying [BOSH][1]. It will allow
you to deploy BOSH via `bosh create-env` style deployments,
as well as deploy BOSH on top of another BOSH similarly to how
most other things are deployed on BOSH.

Quick Start
-----------

To use it, you don't even need to clone this repository!  Just run
the following (using Genesis v2):

```
# create a bosh-deployments repo using the latest version of the bosh kit
genesis init --kit bosh

# create a bosh-deployments repo using v1.0.0 of the bosh kit
genesis init --kit bosh/1.0.0

# create a my-bosh-configs repo using the latest version of the bosh kit
genesis init --kit bosh -d my-bosh-configs
```

Subkits
-------

#### Infrastructures

BOSH can be deployed on many different infrastructures. Each one requires
a different CPI, and configuration. Enabling one of the following subkits
will set up your BOSH to use the corresponding CPI:

- **aws-cpi** - Run BOSH on AWS
- **azure-cpi** - Run BOSH on Microsoft Azure
- **google-cpi** - Run BOSH on Google Cloud Platform
- **openstack-cpi** - Run BOSH on OpenStack (coming soon!)
- **vsphere-cpi** - Run BOSH on vSphere (coming soon!)
- **vcloud-cpi** - Run BOSH on VMWare's vCloud Suite (coming soon!)
- **warden-cpi** - For creating a BOSH-Lite style deployment (coming soon!)

#### Proto-BOSH (bosh create-env) vs Normal BOSH

To choose whether your BOSH will be deployed by `bosh create-env`,
or if it will be deployed as a BOSH deployment managed by another bosh,
you will want to choose one of the following subkits:

- **bosh** - This BOSH will be deployed by another BOSH. The advantages here
  are that when re-deploying BOSH, downtime will be reduced significantly,
  as the BOSH director managing this BOSH can handle compilation on other VMs,
  and perform in-place updates on the VM. Additionally, if this BOSH goes down,
  its director will resurrect it, so that it can resume monitoring the VMs it
  has deployed.
- **bosh-init** - Enables BOSH to be deployed via `bosh create-env` (previously
  `bosh-init`). This is required at soem point in your infrastructure, to boot
  up the iniital BOSH (a.k.a. Proto-BOSH).

Confused? See [our article on the Proto-BOSH][2] concepts.

If you choose the `bosh-init` subkit during the interactive new environment setup,
an additional subkit for `<CPI>_init` will be selected, to enable the CPI-specific
changes for `bosh create-env`. If you are writing your configs by hand, make sure
to include these if appropriate.

#### SHIELD

The SHIELD subit adds the SHIELD agent to the BOSH Director, so that its data
can be backed up via SHIELD.

Params
------

#### Base Params

- **params.static_ip** - In order to set up BOSH, and provide it with a custom
  SSL certificate, the static IP for BOSH needs to be provided during interactive
  environment setup. Otherwise, your BOSH CLI may not be able to talk to the
  director!
- **params.bosh_hostname** - If there is a DNS entry for the above static IP,
  provide it here, so that the BOSH SSL certificate will be valid for this name
  as well as the IP address. If there is no DNS entry, you should enter `bosh` here.
- **params.ntp** - A list of NTP servers that BOSH and the VMs it deploys will use

#### AWS CPI

- **AWS Access Key** - AWS credentials are needed for hte Director to Direct. During
  interactive environment setup, you will be prompted for the AWS Access key to use.
  It will be stored in Vault at `secret/path/to/env/bosh/aws:access_key`.
- **AWS Secret Key** - The secret key for the above access key, prompted similarly.
  It will be stored in Vault at `secret/path/to/env/bosh/aws:secret_key`.
- **params.aws_region** - Defines the AWS region for VMs that will be deployed by
  this director
- **params.aws_default_sgs** - Defines the default security groups to provide VMs
  that are will be deployed by this director

If building a Proto-BOSH on AWS, the following IaaS information is also needed for
the `aws-init` subkit:

- **params.aws_subnet_id** - The AWS Subnet ID for the subnet BOSH will be placed on
- **params.aws_security_groups** - The security groups given to the BOSH Director VM.
- **params.aws_instance_type** - How big should your BOSH Director be?
- **params.aws_disk_type** - Should the Director get `gp2` or `standard` storage?

#### Azure CPI

- **Azure Client ID** - The Azure Client ID use to authenticate BOSH to Azure's API.
  This will be prompted during interactive environment setup, and placed in Vault at
  `secret/path/to/env/bosh/azure:client_id`.
- **Azure Client Secret** - The Azure Client Secret for the above Client ID. It will
  be placed in vault at `secret/path/to/env/bosh/azure:client_secret`.
- **Azure Tenant ID** - The Azure Tenant ID associated with the account being used
  by BOSH. This will be prompted for, and placed in Vault at
  `secret/path/to/env/bosh/azure:tenant_id`
- **Azure Subscription ID** - The Azure Subscription ID is also required by BOSH.
  It will be prompted for, and placed in Vault at `secret/path/to/env/bosh/azure:subscription_id`.
- **params.azure_resource_group** - Determines which Azure Resource Group BOSH VMs will
  be placed in. This must match the Resource Group BOSH was deployed in, or BOSH will
  be unable to talk to the VMs it creates (unless you have advanced networking configs
  allowing cross-Resource-Group traffic).
- **params.azure_default_sg** - Defines the default security group for VMs created
  with this BOSH director.
- **params.azure_environment** - If necessary, you can override this to specify
  that you wish to use `AzureChinaCloud`, `AzureUSGovernment`, or other Azure
  environments. Defaults to `AzureCloud`.

If building a Proto-BOSH on Azure, the following IaaS information is also needed for
the `azure-init` subkit:

- **params.azure_virtual_network** - Name of the Azure Virtual Network (like a AWS VPC)
  that BOSH will be placed in
- **params.azure_subnet_name** - Name of the Azure subnet that BOSH will be placed in
- **params.azure_instance_type** - Allows you to override the default size of the BOSH
  Director. Defaults to `Standard_D1_v2`.
- **params.azure_availibility_set** - Define the Availability Set for BOSH to be placed
  in. Defaults to `proto-bosh`.
- **params.azure_persistent_disk_type** - Allows the choice between `Standard_LRS` and
  `Premium_LRS` storage. Make sure your instance type is correct for the requested
  disk type.

#### Google CPI

- **GCP Credentials** - The GCP JSON Key used to authenticate with GCP APIs is required.
  It will be prompted for and placed in Vault at `secret/path/to/env/bosh/google:json_key`.
- **params.google_project** - The project ID of the GCP project that your BOSH VMs
  will be deployed to.

If building a Proto-BOSH on GCP, the following IaaS information is also needed for
the `gcp-init` subkit:

- **params.google_network_name** - Name of the GCP network BOSH will be deployed on
- **params.google_subnetwork_name** - Name of the GCP subnetwork BOSH will be deployed on
- **params.google_machine_type** - Allows you to override the size of your BOSH director.
  Defaults to `n1-standard-1`
- **params.google_disk_type** - Allows you to override the disk type for your BOSH
  director. Defaults to `pd-standard`.
- **params.google_availability_zone** - Name of the GCP Availability Zone to place the
  BOSH VM on
- **params.google_tags** - A list of tags to associate with the BOSH Director VM in
  GCP

### OpenStack CPI

- **params.openstack_auth_url** - Auth URL for OpenStack
- **params.openstack_region** - Region in OpenStack to deploy in
- **params.openstack_ssh_key** - Name of the SSH key in OpenStack to associate with VMs
- **params.openstack_default_security_groups** - List of security groups to apply to VMs by default
- **OpenStack Username** - Username to authenticate to OpenStack with
- **OpenStack Password** - Password to authenticate to OpenStack with
- **OpenStack Domain** - OpenStack Domain that BOSH + VMs will be associated with
- **OpenStack Project** - OpenStack Project/Tenant that BOSH + VMs will be associated with

If building a Proto-BOSH on OpenStack, the following IaaS information is also needed for
the `openstick-init` subkit:

- **params.openstack_network_id** - UUID of the Network containing the subnet BOSH is deployed into (not the subnet UUID)
- **params.openstack_flavor** - Instance Type/Flavor in OpenStack to give the BOSH Director VM
- **params.openstack_az** - OpenStack AZ that the BOSH Director VM will be placed in

#### Proto-BOSH Params

The following params are required in all cases for environments deployed using the
`bosh-init` kit. This is required, as `bosh create-env` has no Cloud Config to reference
for IaaS settings.

- **params.subnet_addr** - CIDR notation of the subnet BOSH will be deployed on
- **params.default_gateway** - Gateway IP for the above subnet
- **params.dns** - A list of DNS servers that BOSH will use
- **params.ephemeral_disk_size** - Specifies the size of BOSH's ephemeral disk
- **params.persistent_disk_size** - Specifies how much persistent storage BOSH will get

#### Normal BOSH Params

- **params.bosh** - If using the `bosh` subkit for deploying your BOSH via
  another BOSH Director, you will be prompted for the name of that BOSH director.
  This name should match the alias you have configured in your BOSH config, as it
  will tell Genesis how to communicate with that BOSH Director to deploy BOSH.


#### Shield Params

- **params.shield_key_vault_path** - A Vault path to the SHIELD daemon's public SSH key
  This is used to authenticate the SHIELD daemon to the agent, when running tasks.

  For example: `secret/us/proto/shield/agent:public`

Cloud Config
------------

When deploying a Normal BOSH (not a Proto-BOSH), Cloud Config will be consulted
on the parent BOSH director, to detemine where/how to build the new BOSH Director.
By default this kit will use the following VM type/network/disk pool.i Feel free to
override them in your environment, if you would rather they use entities already
existing in your Cloud Foundry:

```
params:
  bosh_network:   bosh
  bosh_disk_pool: bosh  # Should be at least 50GB
  bosh_vm_type:   small # Should be at least 1 CPU and 2GB of memory
```

[1]: https://bosh.io
[2]: http://www.starkandwayne.com/blog/speeding-up-bosh-init-in-production/
