# BOSH Genesis Kit Manual

The **BOSH Genesis Kit v2** deploys a BOSH Director, either as a standalone deployment (via `bosh create-env`) or by way of another director.  It is based on the upstream [bosh-deployment](https://github.com/cloudfoundry/bosh-deployment) repository, and allows the use of its ops files as Genesis features, as well as Genesis best-practices features from the v1.x series and support for local ops files.

# General Usage Guidelines

As per usual with Genesis kits, you will need a Genesis deployment repository
to contain your environment file.  If you don't already have one from a previous `cf` version, run `genesis init -k bosh/<version>`, where `<version>` is replaced with the current BOSH Genesis Kit version.  If you have this already, you'll need to download the latest copy of this kit via `genesis fetch-kit` from within that directory.

Once in the Genesis `bosh` deployment repository, and run `genesis new <env>` to create a new env file, replacing `<env>` with your desired env.  This will walk you through a wizard that will populate the desired features and the corresponding parameters.

Once you have an env file, you may want to manually change parameters or features. The rest of this document covers how to modify your environment files to make use of provided features.

## Deploying as a `create-env`

On a completely new system, you will have to deploy at least one BOSH director using the `bosh create-env` method, which we call a Proto-BOSH.

When you run `genesis new <env>`, you will be prompted with the following question:

```sh
$ genesis new sample-env
Setting up new environment sample-env based on kit bosh/2.0.0 (dev) ...

Verifying availability of vault 'my-vault' (http://127.0.0.1:8204)...ok

Is this a proto-BOSH director?
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

The more common way of deploying a new BOSH environment is under an existing proto-BOSH director.  You will often have a separate BOSH director for each environment you're using, such as sandbox, dev, qa and prod, on which you will deploy the bosh deployments used by those environment (cf, blacksmith, prometheus, etc...)

You begin the same way as you would for the proto-BOSH, except when asked if its a proto-BOSH, respond no.  You will then be asked the name of the BOSH director's environment that will be used to deploy your new BOSH director.  This cannot be the same name as the new environment, for the obvious reason.  This will be stored in the environment file under `genesis.bosh-env`.

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
  *Default:* `5y`
- `cert_validity_period` - Validity period of generated X.509 Certificates, expressed in years (#y), months (#m), days (#d) or hours (#h)
  *Default:* `1y`

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

### Normal vs Create-Env Deployments: `proto`

As mentioned in the General Usage Guildlines above, while it is normally expected that a BOSH environment will be deployed by a parent BOSH environment, there needs to be at least one BOSH environment that is deployed via the `bosh create-env` method, that is, a "proto-BOSH".  In the environment file, this is represented by the `proto` feature.  When using the `proto` feature, there are a number of parameters that will be required, depending on the Cloud Infrastructure selected; see next section.

 The following parameters **only** apply to proto-BOSH deployments, and are common across the various Cloud Infrastructure:

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

Each environment must specify at least one feature, which is which Infrastructure will be deployed by the BOSH director.  This determines which CPI will be selected, as well as the required parameters needed to function.  The choices are:

* `vsphere` - for deploying to VMWare vSphere
* `aws` - for deploying to Amazon Web Services
* `azure` - for deploying to Microsoft Azure
* `google` - for deploying to Google Cloud Platform
* `openstack` - for deploying to OpenStack
* `warden` - for deploying to BOSH Warden containers

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

If you also specify the `proto` feature, it requires a bit more configuration:

  - `aws_subnet_id` - The AWS ID of the network subnet in which you wish to deploy your proto-BOSH director.
    **Required**.
  - `aws_security_groups` - A list of security groups that will apply to the proto-BOSH director itself.
    **Required**.
  - `aws_instance_type` - The EC2 instance type to use for deploying the proto-BOSH director.
    Default:*  `m4.large`.
  - `aws_disk_type` - What type of disk to use for the proto-BOSH director's persistent storage.
    *Default:* `gp2`.
  - `ephemeral_disk_size` - Size of the ephemeral disk on the director VM, in Mb.
    *Default:* `25000`

If you are using AWS IAM Instance Profiles instead of access keys, activate the `iam_instance_profile` feature. In this case, you will no longer need an access key pair. If this deployment is a Proto-BOSH, then will need to provide
the following param:

  - `aws_proto_iam_instance_profile` - The instance profile to associate with the Proto-BOSH director you are deploying.
    **Required if proto feature enabled**

Keep in mind that if this is a Proto-BOSH deployment, it will cause both the `create-env` temporary BOSH and the deployed proto-BOSH to use IAM Instance Profile. This means that the bastion host you are deploying from will need to
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

If you also specify the `proto` feature, it requires a bit more configuration:

  - `azure_virtual_network` - The name of the Azure virtual network you wish to deploy your proto-BOSH director into.
    **Required**

  - `azure_subnet_name` - The name of the Azure subnet you wish to deploy to, which must exist within your `azure_virtual_network`.
    **Required**

  - `azure_instance_type` - The Azure compute instance type to use for deploying the proto-BOSH director.
    *Default:* `Standard_D1_v2`.

  - `azure_persistent_disk_type` - What type of disk to use for the proto-BOSH director's persistent storage.  If you specify this, you must be sure to match the disk type to the chosen instance type.
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

If you also specify the `proto` feature, it requires a bit more configuration:

  - `google_network_name` - The name of the Google Virtual Network to deploy the proto-BOSH director into.
    **Required**
  - `google_subnetwork_name` - The name of the Google Virtual Network Sub-network to deploy the proto-BOSH director into. This must exist within the given `google_network_name`.
    **Required**
  - `google_availability_zone` - The name of the Google Availability Zone into which to deploy the proto-BOSH director compute instance.
    **Required**
  - `google_tags` - A list of tags to attach to the proto-BOSH director compute instance.
    **Required**
  - `google_machine_type` - The type of compute instance to allocate for the proto-BOSH director.
    *Default:* `n1-standard-2`
  - `google_disk_type` - What type of disk to provision for the proto-BOSH director's persistent storage.
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

If you also specify the `proto` feature, it requires a bit more configuration:

  - `openstack_network_id` - The UUID of the OpenStack Network to deploy the proto-BOSH director into.
    **Required**

  - `openstack_flavor` - The OpenStack flavor to use for the proto-BOSH director VM.
    **Required**

  - `openstack_az` - The availability zone to deploy the proto-BOSH director VM into.
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

If you also specify the `proto` feature, it requires a bit more configuration:

  - `vsphere_network` - The name of the vCenter virtual network to deploy the proto-BOSH director into.
    **Required**
  - `vsphere_disk_type` - The type of disk allocation to use for the proto-BOSH director's persistent storage.
    *Default:* `preallocated`.
  - `vsphere_cpu` - How many virtual CPUs to allocate for the proto-BOSH director.
    *Default:* `2`
  - `vsphere_ram` - How much memory to allocate for the proto-BOSH director, specified in megabytes.
    *Default:* `8192`
  - `vsphere_disk` - How much persistent storage to allocate for the proto-BOSH director, specified in megabytes.  *Default:*`40960`

The following secrets will be created during `genesis new` or `genesis add-secrets`, and pulled from the vault when deploying:

- `vsphere:address` - The IP address of your vCenter (VCSA) server that manages the vSphere environment to deploy to.
- `vsphere:user` - The username for authenticating to your vCenter server.
- `vsphere:password` - The password for authenticating to your vCenter server.


#### Deploying to Bosh Warden Containers: `warden`

To deploy a BOSH director in a "BOSH-Lite" configuration using Warden containers for its deployment, use the `warden` feature.  **NOTE:** the `warden` feature does not support `proto` deployments at this time.

### Amazon S3: `s3-blobstore` and `s3-blobstore-iam-instance-profile`

Use the feature flag `s3-blobstore` to use a S3 blobstore for the BOSH director and BOSH Agents. This does not provide any auto data migration from the internal WebDAV blobstore. One approach is to inspect releases and manually upload utilizing the `--fix` switch after enabling this feature.

Secrets required in safe at `blobstore/s3`:

* `access_key`
* `secret_key`

Other parameters included in the environment file under `params`:

* `s3_blobstore_bucket`
* `s3_blobstore_region`

To authenticate with the s3 blobstore using IAM instance profiles, activate the `s3-blobstore-iam-instance-profile` feature as well. If done, the `access_key` and `secret_key` values are no longer required in the Vault. Keep in mind that all VMs deployed by BOSH must also be able to authenticate to the blobstore, so an IAM Instance Profile authorized to get secrets from the S3 blobstore must be associated with every VM deployed by this BOSH, including compilation VMs. To do so,Add below param to non-proto director which attaches IAM instance profile to the vm's created by it.
    **Required**
  - `iam_profile` - The  IAM instance profile to associate with the VMs created by non-proto directors for accessing the S3 blobstore

The `s3_blobstore` feature can be used regardless of the Cloud Infrastructure being used, but the `s3-blobstore-iam-instance-profile` feature can only be used if the BOSH director is deployed with the `aws` feature.

You can also use `minio-blobstore` feature to use an external Minio blobstore to use instead of the BOSH internal blobstore.

### External Database: `external-db-mysql`, `external-db-postgres`

This kit supports using a database for the BOSH Director, UAA, and CredHub which has been provisioned externally from this kit. This does not provide any automatic data migration in the case that you already have any existing
internal databases.

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

### Disable Operator Access: `skip-op-users`

By default, netops and sysops users are added to the bosh director so that operators can SSH into the instance in case of a problem.  If this violates security protocols, it can be disables via this feature.  Keep in mind that disabling it can mean that you could potentially be locked out of your BOSH director and lose all access to its deployments, with the only remedy being to delete them from the Cloud Infrastructure provider.

### Vault on Credhub: `vault-credhub-proxy`

To enable communication with the BOSH internal credhub using [safe](https://github.com/starkandwayne/safe), activate the `vault-credhub-proxy` feature.

This will activate the `vault-proxy-login` addon. This addon will create and auth to a `safe target` pointing at this proxy. Please note that this proxy does not support every safe function. It does support basic functionality making credhub management a bit easier.

### Backing Blacksmith: `blacksmith-integration`

To enable blacksmith use of this BOSH director for deploying services activate the `blacksmith-integration` feature. This will add a 'blacksmith' user that only has permissions to interact with its own deployments and upload releases and stemcells and expose it via exodus data to the blacksmith kit.

### Prometheus Integration: `node-exporter`

To add the node exporter for integration with Prometheus, add the `node-exporter` feature.  This is only needed when using `proto` features, as it is normally integrated via the runtime config.  There are no parameters needed for this feature.

## Features Provided by `bosh-deployment`

One of the advantages of using the upstream `bosh-deployment` Github repository is the availabilty of the ops files it provides.  This Genesis kit uses select components to form the base functionality, and further ops files to add selected features for best practices.  However, you can add the upstream ops files directly as features, and set any bosh variables that it uses in the env file under `bosh-variables:`

For example, if you wanted to add a second network, you could add the following to your environment file:

```
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

## Providing your Own Features

Beyond the built-in best practice features provided by the Genesis kit, and the upstream ops files, you can also create organization-specific ops file in your own.  If you would like to provide ops files for custom features, you can do so by adding them under:

```
./ops/<feature-name>.yml
```

and reference them in your environment file via:
```YAML
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
  
      Usage: `genesis do <env> -- upload-stemcells <options> <arguments>
      
    Options:
      --dl               download the stemcell file to the local machine then
                         upload it.  This may be necessary if the BOSH director
                         does not have direct access to the internet.
      
    --fix              upload the stemcell even if its already uploaded
      
      --os <str>         use the os <str> (defaults to ubuntu-bionic)
      
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

  This addon used to merge these configurations with the existing default
  runtime on the BOSH director, but they now use separate named runtime
  configs that are merged on deployment.  You can use the legacy behaviour by
  specifying `-d` in the `runtime-config` addon call if you wish.  To get a
  dry-run to see what would be uploaded you can specify `-n` to the call.

  NOTE:  If used previously, there may be remnants of the old runtime config
  in your existing default runtime config -- please remove these manually by
  downloading the config, editing it and uploading it again.

- `credhub-login` - Connect and authenticate to the Credhub server on this BOSH director.  This will configure the `~/.credhub/config.json` file with a token for continued access, but it does time out in about an hour.

-  `vault-proxy-login` - If the `vault-credhub-proxy` feature is enabled, then this add-on is available to connect and authenticate the associated vault-credhub proxy process running on the BOSH director, and store the token in `~/.saferc` for continued access.

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
