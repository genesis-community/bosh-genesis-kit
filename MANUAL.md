# BOSH Genesis Kit Manual

The **BOSH Genesis Kit v3** deploys a BOSH Director, either as a standalone management deployment (via `bosh create-env`) or by way of another director. It is based on the upstream [bosh-deployment](https://github.com/cloudfoundry/bosh-deployment) repository, and allows the use of its ops files as Genesis features, as well as Genesis best-practices features from previous versions and support for local ops files.

> **Note:** In this kit, we now use the term "management BOSH" or "mgmt" to refer to standalone BOSH directors deployed via `bosh create-env`. The legacy term "proto-BOSH" is considered deprecated, though it still appears in some code and configuration for backward compatibility.

## Table of Contents

1. [Genesis v3 Compatibility](#genesis-v3-compatibility)
2. [General Usage Guidelines](#general-usage-guidelines)
    - [Deploying as a create-env (Proto-BOSH)](#deploying-as-a-create-env)
    - [Deploying on an existing BOSH director](#deploying-on-an-existing-bosh-director)
3. [Base Parameters](#base-parameters)
    - [BOSH Resurrector Parameters](#bosh-resurrector-parameters)
    - [Sizing and Deployment Parameters](#sizing-and-deployment-parameters)
    - [HTTP(S) Proxy Parameters](#https-proxy-parameters)
4. [Cloud Configuration](#cloud-configuration)
5. [Features](#features)
    - [Feature Relationships and Dependencies](#feature-relationships-and-dependencies)
    - [Cloud Infrastructure Features](#cloud-infrastructure-features)
    - [Blobstore Options](#amazon-s3-s3-blobstore-and-s3-blobstore-iam-instance-profile)
    - [External Database Options](#external-database-external-db-mysql-external-db-postgres-external-db-vault)
    - [OCFP Reference Architecture](#ocfp-reference-architecture)
    - [Trust Parent BOSH](#trust-parent-bosh-trust-parent-bosh)
    - [Other Features](#disable-operator-access-skip-op-users)
6. [Available Addons](#available-addons)
7. [Examples](#examples)

## Genesis v3 Compatibility

This kit is fully compatible with Genesis v3.1.0+ and provides enhanced functionality when used with Genesis v3, including:

- Support for `genesis bosh` commands for streamlined BOSH interactions
- Integration with Genesis v3's improved secret management workflow
- Advanced addon execution with reduced operator intervention
- Support for Genesis v3's environment groups and inheritance

### Minimum Genesis Version

This kit requires Genesis v2.8.12 or later, but for full functionality, we recommend using Genesis v3.1.0 or later. The kit automatically checks for Genesis version compatibility during deployment and will fail if run with an incompatible version.

In the code, you will see:
```perl
check_minimum_genesis_version('3.1.0-rc.14')
```

This check ensures that critical features required by the kit are available in the Genesis version being used.

# General Usage Guidelines

As per usual with Genesis kits, you will need a Genesis deployment repository
to contain your environment file.  If you don't already have one from a previous `cf` version, run `genesis init -k bosh/<version>`, where `<version>` is replaced with the current BOSH Genesis Kit version.  If you have this already, you'll need to download the latest copy of this kit via `genesis fetch-kit` from within that directory.

Once in the Genesis `bosh` deployment repository, and run `genesis new <env>` to create a new env file, replacing `<env>` with your desired env.  This will walk you through a wizard that will populate the desired features and the corresponding parameters.

Once you have an env file, you may want to manually change parameters or features. The rest of this document covers how to modify your environment files to make use of provided features.

## Deploying as a `create-env`

On a completely new system, you will have to deploy at least one BOSH director using the `bosh create-env` method, which we call a management BOSH (or mgmt BOSH). These are typically named with a `-mgmt` suffix (e.g., `us-east-1-mgmt`).

> **Terminology Note:** Previously, these directors were called "Proto-BOSH" directors. We have moved to the more descriptive term "management BOSH" or "mgmt BOSH", though you'll still see references to "proto" in some code, feature flags, and prompts for backward compatibility.

When you run `genesis new <env>`, you will be prompted with the following question:

```sh
$ genesis new sample-env
Setting up new environment sample-env based on kit bosh/3.0.5 (dev) ...

Verifying availability of vault 'my-vault' (http://127.0.0.1:8204)...ok

Is this a management BOSH director? (deployed via create-env)
[y|n] >
```

Responding to this question in the positive will prompt you for details needed to deploy with `create-env` method.  Example data is shown below:

```plain
What static IP do you want to deploy this BOSH director on?
> 10.0.12.4

What network should this BOSH director exist in (in CIDR notation)?
> 10.0.12.0/23

What default gateway (IP address) should this BOSH director use?
> 10.0.12.1

What DNS servers should BOSH use? (leave value empty to end)
1st value > 10.0.13.253
2nd value > 10.0.13.254
3rd value >

```

You will then be prompted for selecting the cloud infrastructure you will be deploying it on.

```
What IaaS will this BOSH director orchestrate?
  1) VMWare vSphere
  2) Amazon Web Services
  3) Microsoft Azure
  4) Google Cloud Platform
  5) OpenStack
  6) BOSH Warden

Select choice >
```

What you select will determine most of the rest of the questions in the wizard.  Answer them with the values appropreate to your infrastructure.  You will next be asked to select the blobstore: you can chose between a local blobstore or an external AWS S3 (or compatible) blobstore.

You will finally be offered to edit the generated environment file, which if you chose to do, will open your chosen editor (via your `$EDITOR` variable) with the contents of that file.  If you use `vim` or `emacs` as your system editor, you will also be presented with this manual in a right-side pane.  This gives you the opportunity to fine-tune your deployment with other features not offered in the wizard.  See the Features section below for features and parameters available.

Once you exit from the editor, or chose not to open it, the secrets for the environment will be generated and stored in the vault selected for this deployment repo.  At the completion of that, the wizard completes with intructions on how to deploy your new environment.

```
Parsing kit secrets descriptions ... done. - 1 seconds

Adding 38 secrets for sample-env under path '/secret/sample/env/bosh/':
  [ 1/38] blobstore/ca X509 certificate - CA, self-signed ... done.
---8<--- snipped ---8<---
  [38/38] op/net SSH public/private keypair - 4096 bits ... done.
Completed - Duration: 36 seconds [35 added/3 skipped/0 errors]

New environment sample-env provisioned!

To deploy, run this:

  genesis deploy 'sample-env'


```

You can now deploy your environment using the specified command.

## Deploying on an existing BOSH director

The more common way of deploying a new BOSH environment is under an existing management BOSH director.  You will often have a separate BOSH director for each environment you're using, such as sandbox, dev, qa and prod, on which you will deploy the bosh deployments used by those environments (cf, blacksmith, prometheus, etc.).

You begin the same way as you would for the management BOSH, except when asked if it's a management BOSH, respond no.  You will then be asked the name of the BOSH director's environment that will be used to deploy your new BOSH director.  This cannot be the same name as the new environment, for the obvious reason.  This will be stored in the environment file under `genesis.bosh-env`.

You will then proceed through the same process as the `create-env` version above.

# Base Parameters

All BOSH deployments require some base configuration regardless of the Cloud Infrastructure being targetted or other optional features.  There are also optional configurations to override defaults for the base deployment.  These can be specified under the `params:` key in the environment's YAML flie.

- `static_ip` - The static IP address to deploy the BOSH director to.  This must exist within the static range of the `bosh_network`   
  **Required**
- `ntp` - A list of NTP hosts to use.
  *Default:* `[0.pool.ntp.org, 1.pool.ntp.org]`.  These defaults, however, often get changed by the IaaS feature flag (see below) in use.
- `session_timeout` - How long should authenticated sessions (via the CLI) last, in days.
  *Default:* `1`
- `bosh_hostname` - The hostname to assign the BOSH director.
  *Default:* `bosh`.
- `trusted_certs` - An optional list of PEM-encoded CA certificates, which will be installed on all BOSH-deployed VMs as part of the trusted system root bundle.
- `availability_zones` - An array (typically with just one member) of availability zones as named in your BOSH cloud config to deploy the BOSH director to.
  *Default:* This typically defaults to `[ z1 ]`, except for in AWS, where it defaults to the name of your region, with `a` appended to it (e.g. `[ us-east-2a ]`).
- `ca_validity_period` - Validity period of generated X.509 CA Certificates, expressed in years (#y), months (#m), days (#d) or hours (#h)
  *Default:* `3653d`
- `cert_validity_period` - Validity period of generated X.509 Certificates, expressed in years (#y), months (#m), days (#d) or hours (#h)
  *Default:* `1096d`
- `credhub_min_days_generated_ca_cert` - The minimum validity period that credhub will use when generating CA certificates, regardless of what the variables definition states.
  *Default:* 3653 # 10 years, average leap years and rounding.
- `credhub_min_days_generated_leaf_cert` -  The minimum validity period that credhub will use when generating leaf (non-CA) certificates, regardless of what the variables definition states.
  *Default:* 1096 # 3 years


## BOSH Resurrector Parameters
for more information about the health monitor/resurrector
https://bosh.io/docs/resurrector/

- `resurrector_minimum_down_jobs` - If the total number of instances that are down in a deployment (within time interval T) is below this number, the Resurrector will always request to fix instances. This decision takes precedence to the percent_threshold check when the # of down instances ≤ minimum_down_jobs. Default is 5.
- `resurrector_percent_threshold` - If the percentage of instances that are down in a deployment (within time interval T) is greater than the threshold percentage, the Resurrector will not request to fix any instance. Going over this threshold is called "meltdown". Default is 0.2 (20%)
- `resurrector_time_threshold` -  Time interval (in seconds) used in the above calculations. Default is 600

## Sizing and Deployment Parameters

- `bosh_network` - The name of the network (per cloud-config) where the BOSH director will be deployed.  *Default:* `bosh`.
- `bosh_vm_type` - The name of the `vm_type` (per cloud-config) that will be used to deploy the BOSH director VM.
  *Default:* `large`.
- `bosh_disk_pool` - The name of the `disk_type` (per cloud-config) that will be used to back the persistent storage of the BOSH director VM.
  *Default:*  `bosh`.

## HTTP(S) Proxy Parameters

- `http_proxy` - (Optional) URL of an HTTP proxy to use for any outbound HTTP (non-TLS) communication.

- `https_proxy` - (Optional) URL of an HTTP proxy to use for any outbound HTTPS (TLS) communication.

- `no_proxy` - A list of IPs, FQDNs, partial domains, etc. to skip the proxy and connect to directly.  This has no effect if the `http_proxy` and `https_proxy` are not set.


# Cloud Configuration

If you are not deploying a proto-BOSH director (i.e. you have not
activated the `proto` feature), Genesis will use your cloud config
to figure out how to provision the BOSH VM.  The defaults are
shown below.  Feel free to override them in your environment, if
you would rather they use entities already existing in your cloud
config:

```
params:
  bosh_vm_type:   small  # at least 1 CPU and 2GB of memory
  bosh_network:   bosh
  bosh_disk_pool: bosh   # at least 50GB of space
```

# Features

## Features Provided by the Genesis Kit

This kit provides optional (and some mandatory) features that can be added to the base environment to augment its behaviour.  Each feature can be configured using various parameters, that are specified under `params:` in the environment file, and by secrets, which are found in vault under `secret/<env-name>/bosh/`

## Feature Relationships and Dependencies

Features in this kit can interact with and depend on each other. Understanding these relationships is important when building your environment configuration.

### Core Feature Dependencies

- **Management BOSH**: If `genesis.use_create_env` is set to `true` or if the `proto` feature is activated, the kit will enforce management BOSH mode and add the `+proto` virtual feature. This is used for deploying standalone BOSH directors via `bosh create-env`.

- **IaaS Providers**: You must select exactly one IaaS provider feature:
  - `vsphere`
  - `aws`
  - `azure`
  - `google`
  - `openstack`
  - `stackit`
  - `warden`

### AWS-Related Features

- When using `aws` or `aws-cpi`:
  - If `iam-instance-profile` is not enabled, the `+aws-secret-access-keys` virtual feature is added
  - If using `s3-blobstore` without `s3-blobstore-iam-instance-profile`, the `+s3-blobstore-secret-access-keys` virtual feature is added

### OCFP Architecture Dependencies

- When using `ocfp`:
  - If `internal-blobstore` is enabled, the `+internal-blobstore` virtual feature is added
  - It is invalid to have both `internal-db` and `external-db-no-tls` features together
  - If `internal-db` is not specified, the `+ocfp-ext-db` virtual feature is added
  - For OCFP management environments (with `-mgmt` suffix), `genesis.use_create_env` must be enabled, and the `+proto` feature is automatically added to deploy as a management BOSH

### Blobstore Dependencies

- When not using `ocfp`:
  - If using `s3-blobstore` or `minio-blobstore`, the `+internal-blobstore` virtual feature is added
  - If using `external-db-postgres` or `external-db-mysql`, the `+external-db` virtual feature is added

### External Database Features

The kit supports the following external database options:
- `external-db-postgres` - Use external PostgreSQL database
- `external-db-mysql` - Use external MySQL database
- `external-db-vault` - Use external database with credentials from Vault (used with OCFP)

### OpenBao Colocation

- The `openbao` feature is valid on both `create-env` (management) directors
  and director-deployed environments, with or without `ocfp`.

- `openbao` and `vault-credhub-proxy` are mutually exclusive at the default
  port: both bind port 8200 on the director's address. Set `openbao_port` to
  a non-default port to combine them.

- When a bloc's management director hosts OpenBao as its secrets provider,
  the director must be deployed (and its OpenBao initialized and unsealed)
  before any environment that uses it as a vault, and secrets migration into
  it (e.g. `ocfp vault migrate`) happens after initialization.

### Virtual Features

The kit uses several "virtual features" (prefixed with `+`) to handle internal dependencies:
- `+aws-secret-access-keys`
- `+s3-blobstore-secret-access-keys`
- `+internal-blobstore`
- `+external-db`
- `+ocfp-ext-db`
- `+proto`

These virtual features are managed internally by the kit and should not be manually specified in your environment file. They are automatically added based on other feature selections.

### Management BOSH vs Regular BOSH Deployments: `proto` feature

As mentioned in the General Usage Guidelines above, while it is normally expected that a BOSH environment will be deployed by a parent BOSH environment, there needs to be at least one BOSH environment that is deployed via the `bosh create-env` method, which we now call a "management BOSH" (previously called "proto-BOSH").

In the environment file, this is represented by the `proto` feature, which is automatically added when:
- `genesis.use_create_env` is set to `true` in your environment file, or 
- You indicate that the environment is a management BOSH during environment creation, or
- You explicitly add the `proto` feature to your environment's feature list

> **Note on Terminology:** The feature is still called `proto` for backward compatibility, even though we now refer to these as "management BOSH" directors in documentation.

When deploying a management BOSH (with the `proto` feature), there are additional parameters required, depending on the Cloud Infrastructure selected.

The following parameters **only** apply to management BOSH deployments, and are common across the various Cloud Infrastructure:

  - `subnet_addr` - The network (in CIDR format) that the proto-BOSH director will be deployed into.
    Example: `10.4.0.0/24`. 
    **Required**
  - `default_gateway` - The IP address of the network gateway (usually a router) that this BOSH director should send all of its network traffic through, by default.
    **Required**
  - `persistent_disk_size` - How big to make the BOSH persistent disk, in megabytes.
    *Default:* `32768`, or 32GB.
  - `dns` - A list of DNS servers (by IP) to consult for name resolution.
    *Default:* `[8.8.8.8, 8.8.4.4]`, but specific cloud infrastructure choices may override it.

Please note that `create-env` and `delete-env` commands have additional
operating system-specific dependencies and (sometimes) limitations documented
in [bosh-cli manual][1].

### Cloud Infrastructure Features

Each environment must specify at least one feature, which is which Infrastructure will be deployed by the BOSH director. This determines which Cloud Provider Interface (CPI) will be selected, as well as the required parameters needed to function.

#### Supported Infrastructure Providers

* `vsphere` - for deploying to VMWare vSphere
* `aws` - for deploying to Amazon Web Services
* `azure` - for deploying to Microsoft Azure
* `google` - for deploying to Google Cloud Platform
* `openstack` - for deploying to OpenStack
* `stackit` - for deploying to STACKIT (Open Telekom Cloud)
* `warden` - for deploying to BOSH Warden containers (typically for development environments)

#### Deploying to Amazon Web Services: `aws`

To deploy a BOSH director onto Amazon Web Services, activate the `aws` feature and provide the following parameters:

  - `aws_region` - The AWS region you wish to deploy to.
    **Required**.
  - `aws_default_sgs` - A list of security groups (SGs) that will apply to all VMs that BOSH deploys.
    **Required**.
  - `aws_key_name` - The name of the EC2 keypair to use when deploying EC2 instances. 
    *Default:* `vcap@<genesis environment>`.
  - `aws_ebs_encryption` - Enables Amazon EBS volume encryption for ephemeral disk.
    *Default:*  `false`

If you are deploying a management BOSH (with the `proto` feature), it requires additional configuration:

  - `aws_subnet_id` - The AWS ID of the network subnet in which you wish to deploy your management BOSH director.
    **Required**.
  - `aws_security_groups` - A list of security groups that will apply to the management BOSH director itself.
    **Required**.
  - `aws_instance_type` - The EC2 instance type to use for deploying the management BOSH director.
    Default:*  `m4.large`.
  - `aws_disk_type` - What type of disk to use for the management BOSH director's persistent storage.
    *Default:* `gp2`.
  - `ephemeral_disk_size` - Size of the ephemeral disk on the director VM, in Mb.
    *Default:* `25000`

If you are using AWS IAM Instance Profiles instead of access keys, activate the `iam_instance_profile` feature. In this case, you will no longer need an access key pair. If this deployment is a management BOSH, then you will need to provide
the following param:

  - `aws_proto_iam_instance_profile` - The instance profile to associate with the management BOSH director you are deploying.
    **Required if proto feature enabled**

Keep in mind that if this is a management BOSH deployment, it will cause both the `create-env` temporary BOSH and the deployed management BOSH to use IAM Instance Profile. This means that the bastion host you are deploying from will need to
have an IAM Instance Profile associated with it already. If you need the bastion host to use access keys, that will require manual overrides.

If you are not using IAM Instance Profiles, then you will need to provide the following secrets in the vault.  They will be populated by either using `genesis new` or by running `genesis add-secrets`.

  - `aws/access_key` - The Amazon Access Key ID (and its counterpart secret key) for use when dealing with the Amazon Web Services API.  

  - `aws:secret_key` - The Amazon Secret Key, the complementary component to the Access Key ID.

#### Deploying to Microsoft Azure: `azure`

To deploy a BOSH director onto Microsoft's Azure cloud platform, activate the `azure` feature and provide the following parameters:

  - `azure_resource_group` - The resource group to place all BOSH-deployed VMs into.  This must match the resource group that BOSH itself was deployed to (for non-proto-BOSHes), or it will be unable to communicate back to the parent BOSH.
    **Required**
  - `azure_default_sg` - The name of the default security group to place BOSH-deployed VMs into.  This security group must exist within the `azure_resource_group`.
    **Required**
  - `azure_environment` - Which Azure cloud to deploy into (i.e.
    AzureCloud, AzureChinaCloud, AzureUSGovernment, etc.).
    *Default:* `AzureCloud`

If you are deploying a management BOSH (with the `proto` feature), it requires additional configuration:

  - `azure_virtual_network` - The name of the Azure virtual network you wish to deploy your management BOSH director into.
    **Required**

  - `azure_subnet_name` - The name of the Azure subnet you wish to deploy to, which must exist within your `azure_virtual_network`.
    **Required**

  - `azure_instance_type` - The Azure compute instance type to use for deploying the management BOSH director.
    *Default:* `Standard_D1_v2`.

  - `azure_persistent_disk_type` - What type of disk to use for the management BOSH director's persistent storage.  If you specify this, you must be sure to match the disk type to the chosen instance type.
    Defaults to `Standard_LRS`.  


The following secrets will be pulled from the vault during deployment, and are put in vault using `genesis new` or `genesis add-secrets` for the environment.

  - `azure:client_id` - Azure Client ID
  - `azure:client_secret` - Azure Client Secret
  - `azure:tenant_id` - Azure Tenant ID
  - `azure:subscription_id` -  Azure Resource Group to be used by BOSH to deploying VMs

#### Deploying to Google Cloud Platform: `google`

To deploy a BOSH director into Google's Cloud Platform, activate the `google` feature and provide the following parameters:

  - `google_project` - The name of the Google Cloud Platform project to deploy to.  This must be the internal ID (the one with a randomized number at the end).
    **Required**

If you are deploying a management BOSH (with the `proto` feature), it requires additional configuration:

  - `google_network_name` - The name of the Google Virtual Network to deploy the management BOSH director into.
    **Required**
  - `google_subnetwork_name` - The name of the Google Virtual Network Sub-network to deploy the management BOSH director into. This must exist within the given `google_network_name`.
    **Required**
  - `google_availability_zone` - The name of the Google Availability Zone into which to deploy the management BOSH director compute instance.
    **Required**
  - `google_tags` - A list of tags to attach to the management BOSH director compute instance.
    **Required**
  - `google_machine_type` - The type of compute instance to allocate for the management BOSH director.
    *Default:* `n1-standard-2`
  - `google_disk_type` - What type of disk to provision for the management BOSH director's persistent storage.
    *Default:* `pd-standard`
  - `ephemeral_external_ip` - Determines if an external ip is provided for the instance.
    *Default:* `false`
  - `ephemeral_disk_size` - The size of the ephemeral disks, in GB.
    *Default:* `40`

The following secrets will be added to the vault during `genesis new` or `genesis add-secrets` for the environment, then pulled from the vault on deployment:

- `google:json_key`  - Your IAM service account will have credentials in the form of a JSON blob that must be given to BOSH in order to communicate with the  Google Cloud Platform APIs.

#### Deploying to Openstack: `openstack`

To deploy a BOSH director onto an OpenStack virtualization cluster, activate the `openstack` feature and provide the following parameters:

  - `openstack_auth_url` - The full URL to the OpenStack authentication backend.
    **Required**

  - `openstack_region` - What region to deploy the BOSH director to.  **Required**

  - `openstack_ssh_key` - The name of the SSH key to use when provisioning virtual machines.  This key will be placed on the VMs, allowing operators to troubleshoot them.
    **Required**

  - `openstack_default_security_groups` - A list of security groups to apply to BOSH-deployed VMs by default.
    **Required**

If you are deploying a management BOSH (with the `proto` feature), it requires additional configuration:

  - `openstack_network_id` - The UUID of the OpenStack Network to deploy the management BOSH director into.
    **Required**

  - `openstack_flavor` - The OpenStack flavor to use for the management BOSH director VM.
    **Required**

  - `openstack_az` - The availability zone to deploy the management BOSH director VM into.
    **Required**

The following secrets will be pulled from the vault:

  - `openstack/creds:username`  - The OpenStack username.
  - `openstack/creds:password` - The password for the OpenStack username.
  - `openstack/creds:project` - The name of the OpenStack project under which to create the VMs.
  - `openstack/creds:domain` - The name of the OpenStack domain to use.

#### Deploying to VMWare vSphere: `vsphere`

To deploy a BOSH director onto a vCenter-managed vSphere ESXi cluster (v5.5 or newer), activate the `vsphere` feature and provide the following parameters:

  - `vsphere_datacenter` - The name of the vSphere data center where BOSH will deploy things.
    **Required**

  -  `vsphere_clusters` - A YAML list of vSphere cluster names where BOSH will deploy service VMs.  The clusters listed in must exist within the specified data center.  Each cluster can be a string, or a hash in the form of `{<cluster_name>: {resource_pool: <resource_pool_name>}}`
    **Require at least one**

  - `vsphere_ephemeral_datastores` - A YAML list of data store names where the BOSH director will store ephemeral (operating systems) disks.

    **Required**

  - `vsphere_persistent_datastores` - A YAML list of data store names where the BOSH director will store persistent (data) disks.
    **Required**

If you are deploying a management BOSH (with the `proto` feature), it requires additional configuration:

  - `vsphere_network` - The name of the vCenter virtual network to deploy the management BOSH director into.
    **Required**
  - `vsphere_disk_type` - The type of disk allocation to use for the management BOSH director's persistent storage.
    *Default:* `preallocated`.
  - `vsphere_cpu` - How many virtual CPUs to allocate for the management BOSH director.
    *Default:* `2`
  - `vsphere_ram` - How much memory to allocate for the management BOSH director, specified in megabytes.
    *Default:* `8192`
  - `vsphere_disk` - How much persistent storage to allocate for the management BOSH director, specified in megabytes.  *Default:*`40960`

The following secrets will be created during `genesis new` or `genesis add-secrets`, and pulled from the vault when deploying:

- `vsphere:address` - The IP address of your vCenter (VCSA) server that manages the vSphere environment to deploy to.
- `vsphere:user` - The username for authenticating to your vCenter server.
- `vsphere:password` - The password for authenticating to your vCenter server.


#### Deploying to STACKIT: `stackit`

To deploy a BOSH director onto a STACKIT (Open Telekom Cloud) virtualization cluster, activate the `stackit` feature and provide the following parameters:

  - `stackit_auth_url` - The full URL to the STACKIT authentication backend.
    **Required**

  - `stackit_region` - What region to deploy the BOSH director to.  **Required**

  - `stackit_ssh_key` - The name of the SSH key to use when provisioning virtual machines.  This key will be placed on the VMs, allowing operators to troubleshoot them.
    **Required**

  - `stackit_default_security_groups` - A list of security groups to apply to BOSH-deployed VMs by default.
    **Required**

If you are deploying a management BOSH (with the `proto` feature), it requires additional configuration:

  - `stackit_network_id` - The UUID of the STACKIT Network to deploy the management BOSH director into.
    **Required**

  - `stackit_flavor` - The STACKIT flavor to use for the management BOSH director VM.
    **Required**

  - `stackit_az` - The availability zone to deploy the management BOSH director VM into.
    **Required**

The following secrets will be pulled from the vault:

  - `stackit/creds:username`  - The STACKIT username.
  - `stackit/creds:password` - The password for the STACKIT username.
  - `stackit/creds:project` - The name of the STACKIT project under which to create the VMs.
  - `stackit/creds:domain` - The name of the STACKIT domain to use.

#### Deploying to Bosh Warden Containers: `warden`

To deploy a BOSH director in a "BOSH-Lite" configuration using Warden containers for its deployment, use the `warden` feature.  **NOTE:** the `warden` feature does not support management BOSH deployments (via `bosh create-env`) at this time.

## Blobstore Configuration Options

### Amazon S3: `s3-blobstore` and `s3-blobstore-iam-instance-profile`

Use the feature flag `s3-blobstore` to use a S3 blobstore for the BOSH director and BOSH Agents. This does not provide any auto data migration from the internal WebDAV blobstore. One approach is to inspect releases and manually upload utilizing the `--fix` switch after enabling this feature.

Secrets required in safe at `blobstore/s3`:

* `access_key`
* `secret_key`

Other parameters included in the environment file under `params`:

* `s3_blobstore_bucket`
* `s3_blobstore_region`

To authenticate with the s3 blobstore using IAM instance profiles, activate the `s3-blobstore-iam-instance-profile` feature as well. If done, the `access_key` and `secret_key` values are no longer required in the Vault. Keep in mind that all VMs deployed by BOSH must also be able to authenticate to the blobstore, so an IAM Instance Profile authorized to get secrets from the S3 blobstore must be associated with every VM deployed by this BOSH, including compilation VMs.

Two ways of specifying `iam_instance_profile`:
  - Update cloud_properties of all vm_types in cloud config with `iam_instance_profile`.
    (OR)
  - Add `iam_profile` param to management and regular BOSH directors.

The `s3_blobstore` feature can be used regardless of the Cloud Infrastructure being used, but the `s3-blobstore-iam-instance-profile` feature can only be used if the BOSH director is deployed with the `aws` feature.

You can also use `minio-blobstore` feature to use an external Minio blobstore to use instead of the BOSH internal blobstore.

## Database Configuration Options

### External Database: `external-db-mysql`, `external-db-postgres`, `external-db-vault`

The BOSH Genesis Kit supports using externally provisioned databases for the BOSH Director, UAA, and CredHub components. This provides better scalability, reliability, and maintenance for production deployments.

#### External Database Features

There are three different features available for external database integration:

1. **`external-db-vault`** - The preferred method for OCFP deployments, which reads database connection information from Vault
2. **`external-db-postgres`** - For connecting to external PostgreSQL databases
3. **`external-db-mysql`** - For connecting to external MySQL databases

#### Common External Database Parameters

When using any of the external database features, you'll need to provide:

- `external_db_host` - Hostname of the external database server
- `external_db_ca` - CA certificate to verify the database server's TLS certificate

You can customize the database usernames and names with these parameters:

- `bosh_db_user` - Username for BOSH Director's database authentication (Default: `bosh_user`)
- `credhub_db_user` - Username for CredHub's database authentication (Default: `credhub_user`)
- `uaa_db_user` - Username for UAA's database authentication (Default: `uaa_user`)
- `bosh_db_name` - Name of BOSH Director's database (Default: `bosh`)
- `credhub_db_name` - Name of CredHub's database (Default: `credhub`)
- `uaa_db_name` - Name of UAA's database (Default: `uaa`)

#### TLS Configuration

TLS is enabled by default for connecting to external databases. If your database doesn't support TLS, you can disable it with the `external-db-no-tls` feature.

> **Warning**: Using databases without TLS is not recommended for production deployments as it exposes sensitive data in transit.

#### Using external-db-vault

When using the `external-db-vault` feature (recommended for OCFP deployments), the kit will read database connection information from the following Vault paths:

- `secret/{env-path}/db/bosh`: BOSH Director database connection details
- `secret/{env-path}/db/credhub`: CredHub database connection details
- `secret/{env-path}/db/uaa`: UAA database connection details

Each of these paths should contain the following keys:
- `scheme`: Database scheme (e.g., "postgres")
- `username`: Database username
- `password`: Database password
- `hostname`: Database hostname
- `port`: Database port 
- `database`: Database name
- `ca`: CA certificate for TLS verification

#### Using external-db-postgres or external-db-mysql

When using `external-db-postgres` or `external-db-mysql`, you'll need to provide database credentials in Vault:

- `external-db/bosh_user:password`
- `external-db/credhub_user:password`
- `external-db/uaa_user:password`

## OCFP Reference Architecture

The BOSH Genesis Kit provides comprehensive support for the Open Cloud Foundry Platform (OCFP) Reference Architecture, which is a standardized approach to deploying and managing Cloud Foundry and related components in enterprise environments.

### Overview of OCFP

The OCFP Reference Architecture provides a standardized approach with the following benefits:
- Consistent deployment patterns across different IaaS providers
- Pre-defined integration points for databases, blobstores, and other services
- Automated runtime configuration management
- Standardized monitoring, logging, and metrics collection

#### OCFP Features

To enable OCFP support, add the `ocfp` feature to your environment:

```yaml
kit:
  name: bosh
  version: 3.0.5
  features:
    - vsphere  # or other IaaS provider
    - ocfp
```

When the `ocfp` feature is enabled, it brings in several related features:

- **`external-db-vault`**: Integration with external databases (configured via Vault)
- **`s3-blobstore` or `minio-blobstore`**: External blobstore integration
- **Runtime configs**: Specialized runtime configs for metrics, logging, and tooling

#### OCFP Workflow

The OCFP workflow follows this pattern:

1. **Terraform**: Infrastructure is provisioned via Terraform, which stores values in Vault
   - `secret/tf/{tf-env-path}/dbs/{bosh,credhub,uaa}`

2. **Database Initialization**: External databases are provisioned and credentials stored in Vault
   - `secret/{env-path}/db/{bosh,credhub,uaa}:{hostname,ca,...}`

3. **Environment Initialization**: A Genesis environment file is generated based on Vault values
   - The file uses the `ocfp` and `external-db-vault` features

4. **Deployment**: The BOSH director is deployed with OCFP-specific configurations

5. **Runtime Config Management**: OCFP-specific runtime configs are created and uploaded

#### OCFP Runtime Configs

The OCFP Reference Architecture maintains several runtime configs:

1. **Base Runtime Configs**: (`do ocfp-runtime-configs` or `do orc`)
   - **ocfp-bosh-dns**: BOSH DNS configuration
   - **ocfp-toolbelt**: Essential troubleshooting tools for all VMs

2. **Syslog Runtime Configs**: (`do ocfp-runtime-configs-syslog` or `do osl`)
   - **ocfp-syslog**: Syslog forwarding for Linux VMs
   - **ocfp-windows-syslog**: Syslog forwarding for Windows VMs

3. **System Metrics**: (`do ocfp-runtime-configs-system-metrics` or `do osm`)
   - **ocfp-system-metrics**: VM metrics collection

#### OCFP External Database Integration

This kit supports using external databases for the BOSH Director, UAA, and CredHub which have been provisioned externally.

The OCFP Reference Architecture approach to external database integration is:

1. **Terraform**: Computes values and places them in Vault at standardized paths:
   - `secret/tf/{tf-env-path}/dbs/{bosh,credhub,uaa}`

2. **Database Initialization**: The OCFP database initialization process:
   - Creates the necessary databases and users
   - Sets appropriate permissions
   - Stores connection information in Vault at:
     `secret/{env-path}/db/{bosh,credhub,uaa}:{hostname,ca,...}`

3. **Environment Initialization**: The environment file is generated with the `external-db-vault` feature

4. **Deployment**: When deployed, the BOSH director connects to the external databases using information from Vault

By default, SSL encryption is used for database connections. The database CA certificates are stored at:
`secret/{env-path}/db/{bosh,credhub,uaa}:ca`

#### OCFP Management Environments

OCFP supports special management environments (named with `-mgmt` suffix) which are deployed as standalone BOSH directors via `bosh create-env`. These environments require:

```yaml
genesis:
  use_create_env: true
```

When the environment name ends with `-mgmt` and the `ocfp` feature is enabled, the kit will automatically add the `proto` feature (which triggers management BOSH deployment mode).

#### Legacy External Database Support

To use an external Postgres database, activate the `external-db-postgres`feature.

To use an external MySQL database, activate the `external-db-mysql` feature.

When using either of these features, the following parameters are required:

  - `external_db_host` - The hostname of the database for the BOSH Director, CredHub, and UAA to connect to.
  - `external_db_ca` - The CA certificate to use to verify the certificate served by the external database instance.

TLS is enabled by default for connecting to the external database. TLS can be disabled with the feature `external-db-no-tls`.

The database usernames and names can be customized with the following
parameters:

  - `bosh_db_user` - The username that the BOSH Director authenticates to the database with.
    *Default:* `bosh_user`
  - `credhub_db_user` - The username that CredHub authenticates to the database with.
    *Default:* `credhub_user`
  - `uaa_db_user` - The username that UAA authenticates to the database with.
    *Default:* `uaa_user`.
  - `bosh_db_name` - The name of the database that BOSH will connect to. 
    *Default:* `bosh`.
  - `credhub_db_name` - The name of the database that CredHub will connect to.
    *Default:* `credhub`.
  - `uaa_db_name` - The name of the database that UAA will connect to.
    *Default:* `uaa`.

### Compile Releases from Source: `source-release`

BOSH Genesis Kit v2.0.0 improves the deployment experience by using compiled releases, significantly speeding it up.  However, you may need to compile from source, especially if you're trying to include an upstream fix that isn't available in precompiled form yet.  To do this, use the `source-release` feature for the default source releases, and if you need a specific release, override it in your environment YAML file.

## Additional Features

### Disable Operator Access: `skip-op-users`

By default, netops and sysops users are added to the bosh director so that operators can SSH into the instance in case of a problem.  If this violates security protocols, it can be disables via this feature.  Keep in mind that disabling it can mean that you could potentially be locked out of your BOSH director and lose all access to its deployments, with the only remedy being to delete them from the Cloud Infrastructure provider.

### Vault on Credhub: `vault-credhub-proxy`

To enable communication with the BOSH internal credhub using [safe](https://github.com/cloudfoundry-community/safe), activate the `vault-credhub-proxy` feature.

This will activate the `vault-proxy-login` addon. This addon will create and auth to a `safe target` pointing at this proxy. Please note that this proxy does not support every safe function. It does support basic functionality making credhub management a bit easier.

### Colocated OpenBao Server: `openbao`

The `openbao` feature colocates an [OpenBao](https://openbao.org/) server (the
open-source Vault fork) on the BOSH director VM, using the
[openbao-boshrelease](https://github.com/cloudfoundry-community/openbao-boshrelease).
This gives an environment a secrets store without a separate deployment — most
useful for management (`create-env`) directors that anchor a bloc, where it can
serve as the Genesis secrets provider for everything the bloc deploys.

This feature is opt-in. Add `openbao` to the feature list:

```yaml
kit:
  features:
    - openbao
```

Parameters:

- `openbao_port` - the HTTPS listener port on the director's `static_ip`
  (default: `8200`)

- `openbao_ui` - enable the OpenBao web UI (default: `false`)

Details:

- The server listens at `https://<params.static_ip>:<openbao_port>`, with TLS
  certificates generated by the kit under
  `secret/<env-path>/bosh/openbao/{ca,server}` (the server certificate carries
  the static IP as a SAN).

- Storage is single-node Raft on the director's persistent disk
  (`/var/vcap/store/openbao/raft`). The process is managed by monit wrapping
  bpm, like the other director jobs.

- After first deploy the server is up but **uninitialized**. Run
  `genesis <env> do openbao-init` to initialize it (Shamir 5 key shares,
  threshold 3). Unseal keys and the initial root token are printed exactly
  once for operator capture, and backed up to the deploying vault under
  `<secrets_base>/openbao/seal/keys` and `<secrets_base>/openbao/root_token`.
  They are never written to the director VM. A copy of the seal keys is also
  stored in-cluster at `secret/vault/seal/keys` (the `safe` auto-unseal
  convention path).

- OpenBao seals whenever the process or VM restarts. Run
  `genesis <env> do openbao-unseal` to bring it back; it uses the seal-key
  backup in the deploying vault automatically when available.

- The exodus data records `openbao_url` and the CA certificate for downstream
  consumers.

- **Port conflict**: `openbao` and `vault-credhub-proxy` both bind port 8200
  on the director. The kit refuses the combination unless `openbao_port` is
  moved to a different port.

See `docs/openbao-operations.md` in this kit for the full operations runbook
(init custody rules, unseal, seal, rekey, root-token rotation, backup and
restore, and disaster recovery).

### Backing Blacksmith: `blacksmith-integration`

To enable blacksmith use of this BOSH director for deploying services activate the `blacksmith-integration` feature. This will add a 'blacksmith' user that only has permissions to interact with its own deployments and upload releases and stemcells and expose it via exodus data to the blacksmith kit.

### Prometheus Integration: `node-exporter`

To add the node exporter for integration with Prometheus, add the `node-exporter` feature.  This is only needed when using `proto` features, as it is normally integrated via the runtime config.  There are no parameters needed for this feature.

### Trust Parent BOSH: `trust-parent-bosh`

Adds the parent (management) BOSH director's CA certificate to the trusted certificates list for all VMs deployed by this child BOSH director. This enables secure communication between child-deployed VMs and the parent BOSH that deployed this director.

- **Applicability**: Only for non-create-env (child) BOSH deployments
- **Auto-enabled**: For OCFP OCF environments
- **Required Parameter**: `genesis.bosh_env` (the name of the parent BOSH environment)
- **Exodus Dependency**: Requires `exodus/<parent_env>/bosh:ca_cert` to exist

When using this feature with non-OCFP deployments, you must specify the parent BOSH environment name:

```yaml
kit:
  features:
    - trust-parent-bosh

genesis:
  bosh_env: us-west-1-mgmt
```

For OCFP OCF environments, this feature is automatically enabled and uses `genesis.bosh_env` to determine the parent BOSH environment.

## Customizing with Additional Features

### Features Provided by `bosh-deployment`

One of the advantages of using the upstream `bosh-deployment` Github repository is the availabilty of the ops files it provides.  This Genesis kit uses select components to form the base functionality, and further ops files to add selected features for best practices.  However, you can add the upstream ops files directly as features, and set any bosh variables that it uses in the env file under `bosh-variables:`

For example, if you wanted to add a second network, you could add the following to your environment file:

```yaml
kit:
  features:
     ...other features...
     bosh-deployment/misc/second-network
     
bosh-variables:
  second_internal_cidr: <value>
  second_internal_gw: <value>
  second_internal_ip: <value>
```

The feature is the path of the ops file, without the `.yml` extension.  The ops file will be applied in order they appear in the features list, so you may have to pick specific order to make sure it works, or is not further modified by latter features.

### Providing your Own Features

Beyond the built-in best practice features provided by the Genesis kit, and the upstream ops files, you can also create organization-specific ops file in your own.  If you would like to provide ops files for custom features, you can do so by adding them under:

```
./ops/<feature-name>.yml
```

and reference them in your environment file via:
```yaml
kit:
  features:
  - <feature-name>
```

Like the upstream ops file, the order of the features list may matter.  Also, if your feature name matches an internal feature name, the internal feature will be used.

# Available Addons

- `alias` - Set up a local BOSH alias for this director. This reads the X.509 Certificate Authority Certificate from the vault, without bothering you for it, which can be quite handy.
  
- `login` - Authenticate to this director.  This sets up an alias in the process.  Administrator credentials are read from the vault automatically.
  
- `upload-stemcells` - Run through a nifty console wizard to choose the correct type (based on deployed CPI) and vintage (based on user selection) of stemcell, and automatically upload them to the new director.  This requires internet access, both from the jumpbox it gets executed on, and from the BOSH director itself.
  
  You can also specify one or more versions on the command line to skip the wizard, including specifying the latest minor version using the format of `<major>.latest`.  It will also take a `--fix` option to forcibly reinstall the stemcells.
  
      Usage: `genesis <env> do upload-stemcells -- <options> <arguments>
      
    Options:
      --dl               download the stemcell file to the local machine then
                         upload it.  This may be necessary if the BOSH director
                         does not have direct access to the internet.
      
    --fix              upload the stemcell even if its already uploaded
      
      --os <str>         use the os <str> (defaults to ubuntu-jammy)
      
      --light            use light stemcells instead of full ones
      
      --dry-run          provide details on the listed or selected stemcells, but
                         dont upload them to the director.
      
      Arguments: 
      <version> ...      specify one or more versions of default or last
                         specified #y{--os} option
      
      <os>@<version> ... specify one or more versions of the given OS
      
      <file> ...         specify one or more local stemcell file
      
                         Version, os@version, and files can be mixed in a single
                         call.  Will be interactive if no version is specified.
  
- `download-stemcells` - Similar to interface for `upload-stemcells`, it allows you to download a stemcell that can later be uploaded from an environment that doesn't have access to the internet via the upload-stemcells with the file as an argument. Same options as `upload-stemcells` except `--fix`, `--dl` and `--dry-run`

- `runtime-config` - Generates runtime configurations for the features
  provided by this BOSH genesis kit.  Specifically, enabling ops access and
  BOSH DNS.  The following features and parameters will be used to build these
  configurations:

  Features:
    - bosh-dns-healthcheck - turn on the BOSH DNS healthcheck.  This uses
      mutual TLS to ensure all the instances are healthy.

    - netop-access - turn on netop access to all VMs deployed by this BOSH via
      a 4096-bit SSH key

    - sysop-access - turn on `sysop` user access via password

  Parameters:
    - dns_cache - enable DNS caching (true by default)

    - dns_deployments_whitelist - a list of dns deployment names/patterns for
      which to enable BOSH DNS on.  It is required to list CF and CF App
      Autoscaler deployments, but others can be added.

    - syslog.custom_rule - free-form rsyslog rule text passed through to
      the syslog_forwarder (and syslog_forwarder_windows) properties as
      `syslog.custom_rule`.  Useful for site-specific log routing (filter
      by app name, tee to a second target, etc.) without having to fork
      the kit.  Multi-line rulesets are preserved verbatim; when unset
      the generated runtime config is unchanged.  Set it under
      `bosh-configs.runtime.syslog.params.custom_rule` in the env file,
      using a YAML multiline block scalar (`|-` recommended) so the
      rsyslog syntax survives intact:

      ```
      bosh-configs:
        runtime:
          syslog:
            params:
              custom_rule: |-
                if $programname == 'my-app' then {
                  action(type="omfwd" target="logs.example.com" port="514" protocol="tcp")
                  stop
                }
      ```

  This addon used to merge these configurations with the existing default
  runtime on the BOSH director, but they now use separate named runtime
  configs that are merged on deployment.  You can use the legacy behaviour by
  specifying `-d` in the `runtime-config` addon call if you wish.  To get a
  dry-run to see what would be uploaded you can specify `-n` to the call.

  NOTE:  If used previously, there may be remnants of the old runtime config
  in your existing default runtime config -- please remove these manually by
  downloading the config, editing it and uploading it again.

- `credhub-login` - Connect and authenticate to the Credhub server on this BOSH director.  This will configure the `~/.credhub/config.json` file with a token for continued access, but it does time out in about an hour.

- `vault-proxy-login` - If the `vault-credhub-proxy` feature is enabled, then this add-on is available to connect and authenticate the associated vault-credhub proxy process running on the BOSH director, and store the token in `~/.saferc` for continued access.

- `openbao-init` (alias `oi`) - If the `openbao` feature is enabled, initialize the colocated OpenBao server (Shamir 5 shares, threshold 3). Prints the unseal keys and initial root token exactly once for operator capture and backs them up to the deploying vault. Run this once, right after the first deploy. Capture rules: run under `umask 077`; if logging, use `script(1)` to a `0600` file — never a tmux pane, never `/tmp`.

- `openbao-unseal` (alias `ou`) - Unseal the colocated OpenBao server after a restart or recreate. Uses the seal-key backup in the deploying vault automatically when available, and prompts for keys otherwise.

- `openbao-seal` (alias `os`) - Seal the colocated OpenBao server immediately (incident response). Everything it serves becomes unavailable until unsealed.

- `openbao-status` (alias `ost`) - Report the colocated OpenBao server's health, availability, and seal state.

- `openbao-target` (alias `ot`) - Create a `safe` target for the colocated OpenBao server and authenticate with the given auth method (default `token`).

- `print-env` - Outputs shell environment variables needed to connect to this BOSH director. Can be used with `eval $(genesis <env> do print-env)` to set up your shell environment.

  ```
  Options:
    --bosh             print only the BOSH environment variables (BOSH_*)
    --credhub          print only the CredHub environment variables (CREDHUB_*)
    --ssh              print the script needed to connect to the BOSH director via SSH
    --key-path <path>  specify the path of the SSH key to be created
    --with-proxy       include BOSH_ALL_PROXY setup for using socks5 proxy
  ```

  If no options are specified, all environment variables will be printed.

- `ocfp-runtime-configs` or `orc` - When using the OCFP reference architecture, generates and uploads the base OCFP runtime configs to the BOSH director. These include:
  - `ocfp-bosh-dns`: BOSH DNS configuration
  - `ocfp-toolbelt`: Essential troubleshooting tools for all VMs

  ```
  Options:
    -y    Upload changes without prompting for confirmation
  ```

- `ocfp-runtime-configs-syslog` or `osl` - When using the OCFP reference architecture, generates and uploads the syslog forwarding runtime configs to the BOSH director. These include:
  - `ocfp-syslog`: Syslog forwarding for Linux VMs
  - `ocfp-windows-syslog`: Syslog forwarding for Windows VMs

  ```
  Options:
    -y    Upload changes without prompting for confirmation
  ```

- `ocfp-runtime-configs-system-metrics` or `osm` - When using the OCFP reference architecture, generates and uploads the system metrics runtime config to the BOSH director:
  - `ocfp-system-metrics`: VM metrics collection

  ```
  Options:
    -y    Upload changes without prompting for confirmation
  ```

- `resurrection` or `easter` - Controls the BOSH Resurrector, which automatically tries to recover VMs in a failed state:
  
  ```
  Options:
    on      Enable the Resurrector (default)
    off     Disable the Resurrector
    status  Show current Resurrector status
  ```

# Examples

Deploying BOSH director to vSphere

```yaml
---
kit:
  name:    bosh
  version: 2.0.0
  features:
    - vsphere

genesis:
  env: acme-us-east-1-prod
  bosh_env: acme-us-east-1-mngt

params:
  static_ip: 10.0.134.4

  # vSphere
  vsphere_ip:         10.0.0.254
  vsphere_datacenter: prod-esx-01
  vsphere_clusters:
    - cf1

  vsphere_ephemeral_datastores:
    - vol20
    - vol21
    - vol22
    - vol23

  vsphere_persistent_datastores:
    - san1
    - san3
```


# History

Version 1.0.0 was the first version to support Genesis 2.6 hooks for addon scripts and `genesis info`.

Version 2.0.0 was refactored to make use of the upstream bosh-deployment repository.

[1]: https://bosh.io/docs/cli-v2-install/#additional-dependencies
