# BOSH Genesis Kit Manual

The **BOSH Genesis Kit** deploys a BOSH Director, either as a
standalone deployment (via `bosh create-env`) or by way of another
director.

# Base Parameters

- `static_ip` - The static IP address to deploy the BOSH director
  to.  This must exist within the static range of the
  `bosh_network`   This parameter is **required**.

- `ntp` - A list of NTP hosts to use.  Defaults to
  `0.pool.ntp.org` and `1.pool.ntp.org`.  These defaults, however,
  often get changed by the IaaS feature flag (see below) in use.

- `session_timeout` - How long should authenticated sessions (via
  the CLI) last, in days.  Defaults to 1 day.

- `bosh_hostname` - The hostname to assign the BOSH director.
  Defaults to `bosh`.

- `trusted_certs` - An optional list of PEM-encoded CA
  certificates, which will be installed on all BOSH-deployed VMs
  as part of the trusted system root bundle.


## Sizing and Deployment Parameters

- `bosh_network` - The name of the network (per cloud-config) where
  the BOSH director will be deployed.  Defaults to `bosh`.

- `stemcell_os` - The operating system you want to deploy the
  BOSH director itself on.  This defaults to `ubuntu-xenial`.

- `stemcell_version` - The version of the stemcell to deploy.
  Defaults to `97.latest`, which is usually what you want, since
  this kit packages pre-compiled BOSH releases that only work on
  xenial 97.x.

- `bosh_vm_type` - The name of the `vm_type` (per cloud-config) that
  will be used to deploy the BOSH director VM.  Defaults to
  `small`.

- `bosh_disk_pool` - The name of the `disk_type` (per cloud-config)
  that will be used to back the persistent storage of the BOSH
  director VM.  Defaults to `bosh`.

- `bosh` - If you are not deploying a proto-BOSH (see next
  section), this parameter must contain the name of the BOSH
  director environment alias to use for deploying this director.

## Proto-BOSH Parameters

If you activate the `proto` feature, you will get a proto-BOSH, a
standalone deployment that gets created _a priori_ via `bosh
create-env`.  The following parameters **only** apply to
proto-BOSH deployments:

  - `subnet_addr` - The network (in CIDR format) that the
    proto-BOSH director will be deployed into.
    Example: `10.4.0.0/24`.  This parameter is **required**.

  - `default_gateway` - The IP address of the network gateway
    (usually a router) that this BOSH director should send all of
    its network traffic through, by default.
    This parameter is **required**.

  - `dns` - A list of DNS servers (by IP) to consult for name
    resolution.

  - `ephemeral_disk_size` - How big to make the BOSH ephemeral
    disk, in megabytes.  Defaults to `25600`, or roughly 24GB.

  - `persistent_disk_size` - How big to make the BOSH persistent
    disk, in megabytes.  Defaults to `32768`, or 32GB.

  - `skip-op-users` - Do not create the sysop and netop users.
    By default, they are created.

## HTTP(S) Proxy Parameters

- `http_proxy` - (Optional) URL of an HTTP proxy to use for any
  outbound HTTP (non-TLS) communication.

- `https_proxy` - (Optional) URL of an HTTP proxy to use for any
  outbound HTTPS (TLS) communication.

- `no_proxy` - A list of IPs, FQDNs, partial domains, etc. to
  skip the proxy and connect to directly.  This has no effect if
  the `http_proxy` and `https_proxy` are not set.

# IaaS Features

You must select exactly one IaaS feature.  Your BOSH director will
be deployed with the correct CPI and configuration to deploy VMs
to that cloud provider.

The following IaaS providers are supported:

- `aws` - Run BOSH on Amazon Web Services.

- `azure` - Run BOSH on Microsoft Azure.

- `google` - Run BOSH on Google's Cloud Platform (GCP).

- `openstack` - Run BOSH on an OpenStack infrastructure.

- `vsphere` - Run BOSH on VMWare vSphere vCenter.

- `warden` - Create a BOSH-lite director; wholly self-contained
  and containerized.

## Deploying to Amazon Web Services

To deploy a BOSH director onto Amazon Web Services, activate the
`aws` feature and provide the following parameters:

  - `aws_region` - The AWS region you wish to deploy to.
    This parameter is **required**.

  - `aws_default_sgs` - A list of security groups (SGs) that will
    apply to all VMs that BOSH deploys.
    This parameter is **required**.

  - `aws_key_name` - The name of the EC2 keypair to use when
    deploying EC2 instances.  This defaults to `vcap@params.env`.

The following secrets will be pulled from the vault:

  - **Access Key** - The Amazon Access Key ID (and its counterpart
    secret key) for use when dealing with the Amazon Web Services
    API.  This is the single most important credential.
    It is stored in the vault, at `secret/$env/bosh/aws`

If you also activate the `proto` feature, you will get a
_Proto-BOSH_, which is deplyed via `bosh create-env`.  That
requires a bit more configuration:

  - `aws_subnet_id` - The AWS ID of the network subnet in which
    you wish to deploy your proto-BOSH director.
    This parameter is **required**.

  - `aws_security_groups` - A list of security groups that will
    apply to the proto-BOSH director itself.
    This parameter is **required**.

  - `aws_instance_type` - The EC2 instance type to use for
    deploying the proto-BOSH director.  Defaults to `m4.large`.

  - `aws_disk_type` - What type of disk to use for the proto-BOSH
    director's persistent storage.  Defaults to `gp2`.

## Deploying to Microsoft Azure

To deploy a BOSH director onto Microsoft's Azure cloud platform,
activate the `azure` feature and provide the following parameters:

  - `azure_resource_group` - The resource group to place all
    BOSH-deployed VMs into.  This must match the resource group
    that BOSH itself was deployed to (for non-proto-BOSHes), or
    it will be unable to communicate back to the parent BOSH.

  - `azure_default_sg` - The name of the default security group
    to place BOSH-deployed VMs into.  This security group must
    exist within the `azure_resource_group`.
    This parameter is **required**.

  - `azure_environment` - Which Azure cloud to deploy into (i.e.
    AzureCloud, AzureChinaCloud, AzureUSGovernment, etc.).
    Defaults to `AzureCloud`.

The following secrets will be pulled from the vault:

  - **Azure Client ID / Secret** - The Azure Client ID and Secret
    for use when dealing with the Azure Cloud API.  This is the
    single most important credential.
    It is stored in the vault, at `secret/$env/bosh/azure`

  - **Tenant and Subscription IDs** - These are also used for
    authentication / resource alotment inside of Azure.
    It is stored in the vault, at `secret/$env/bosh/azure`

If you also activate the `proto` feature, you will get a
_Proto-BOSH_, which is deplyed via `bosh create-env`.  That
requires a bit more configuration:

  - `azure_virtual_network` - The name of the Azure virtual
    network you wish to deploy your proto-BOSH director into.
    This parameter is **required**.

  - `azure_subnet_name` - The name of the Azure subnet you wish to
    deploy to, which must exist within your `azure_virtual_network`.
    This parameter is **required**.

  - `azure_instance_type` - The Azure compute instance type to use
    for deploying the proto-BOSH director.
    Defaults to `Standard_D1_v2`.

  - `azure_persistent_disk_type` - What type of disk to use for
    the proto-BOSH director's persistent storage.
    Defaults to `Standard_LRS`.  If you change this, you must be
    sure to match the disk type to the chosen instance type.

  - `azure_availability_set` - The availability set to deploy the
    proto-BOSH director into.  This won't provide any HA
    capabilities, since the proto-BOSH consists only of a single
    VM.  Defaults to `proto-bosh`.

## Deploying to Google Cloud Platform

To deploy a BOSH director into Google's Cloud Platform, activate
the `google` feature and provide the following parameters:

  - `google_project` - The name of the Google Cloud Platform
    project to deploy to.  This must be the internal ID (the one
    with a randomized number at the end).
    This parameter is **required**.

The following secrets will be pulled from the vault:

  - **Google Credentials** - Your IAM service account will come
    with a JSON blob that must be given to BOSH in order to
    communicate with the Google Cloud Platform APIs.
    It is stored in the vault, at `secret/$env/bosh/google`

If you also activate the `proto` feature, you will get a
_Proto-BOSH_, which is deplyed via `bosh create-env`.  That
requires a bit more configuration:

  - `google_network_name` - The name of the Google Virtual Network
    to deploy the proto-BOSH director into.
    This parameter is **required**.

  - `google_subnetwork_name` - The name of the Google Virtual
    Network Sub-network to deploy the proto-BOSH director into.
    This must exist within the given `google_network_name`.
    This parameter is **required**.

  - `google_availability_zone` - The name of the Google
    Availability Zone into which to deploy the proto-BOSH director
    compute instance.
    This parameter is **required**.

  - `google_tags` - A list of tags to attach to the proto-BOSH
    director compute instance.
    This parameter is **required**.

  - `google_machine_type` - The type of compute instance to
    allocate for the proto-BOSH director.
    Defaults to `n1-standard-1`.

  - `google_disk_type` - What type of disk to provision for the
    proto-BOSH director's persistent storage.
    Defaults to `pd-standard`.

## Deploying to Openstack

To deploy a BOSH director onto an OpenStack virtualization
cluster, activate the `openstack` feature and provide the
following parameters:

  - `openstack_auth_url` - The full URL to the OpenStack
    authentication backend.
    This parameter is **required**.

  - `openstack_region` - What region to deploy the BOSH director
    to.  This parameter is **required**.

  - `openstack_ssh_key` - The name of the SSH key to use when
    provisioning virtual machines.  This key will be placed on the
    VMs, allowing operators to troubleshoot them.
    This parameter is **required**.

  - `openstack_default_security_groups` - A list of security
    groups to apply to BOSH-deployed VMs by default.
    This parameter is **required**.

The following secrets will be pulled from the vault:

  - **OpenStack Username and Password** - These authentication
    credentials will be used for every operation against your
    OpenStack infrastructure.
    They are stored in the vault, at `secret/$env/bosh/openstack`

  - **Project and Domain** - The domain and project are use for
    associating resources used in OpenStack with a specific entity
    (kind of like a tenant).
    They are stored in the vault, at `secret/$env/bosh/openstack`

If you also activate the `proto` feature, you will get a
_Proto-BOSH_, which is deplyed via `bosh create-env`.  That
requires a bit more configuration:

  - `openstack_network_id` - The UUID of the OpenStack Network to
    deploy the proto-BOSH director into.
    This parameter is **required**.

  - `openstack_flavor` - The OpenStack flavor to use for the
    proto-BOSH director VM.
    This parameter is **required**.

  - `openstack_az` - The availability zone to deploy the
    proto-BOSH director VM into.
    This parameter is **required**.

## Deploying to VMWare vSphere

To deploy a BOSH director onto a vCenter-managed vSphere ESXi
cluster (v5.5 or newer), activate the `vsphere` feature and
provide the following parameters:

  - `vsphere_ip` - The IP address of your vCenter (VCSA) server
    that manages the vSphere environment to deploy to.

  - `vsphere_ephemeral_datastores` - A YAML list of data store
    names where the Blacksmith BOSH director will store ephemeral
    (operating systems) disks.

  - `vsphere_persistent_datastores` - A YAML list of data store
    names where the Blacksmith BOSH director will store persistent
    (data) disks.

  - `vsphere_datacenter` - The name of the vSphere data center
    where Blacksmith will deploy things.  The clusters listed in
    `vsphere_clusters` must exist within this data center.

  - `vsphere_clusters` - A YAML list of vSphere cluster names
    where Blacksmith will deploy service VMs.

If you also activate the `proto` feature, you will get a
_Proto-BOSH_, which is deployed via `bosh create-env`.  That
requires a bit more configuration:

  - `vsphere_network` - The name of the vCenter virtual network
    to deploy the proto-BOSH director into.
    This parameter is **required**.

  - `vsphere_disk_type` - The type of disk allocation to use for
    the proto-BOSH director's persistent storage.
    Defaults to `preallocated`.

  - `vsphere_cpu` - How many virtual CPUs to allocate for the
    proto-BOSH director.  Defaults to `2`.

  - `vsphere_ram` - How much memory to allocate for the proto-BOSH
    director, specified in megabytes.  Defaults to `4096`, or 4GB.

  - `vsphere_disk` - How much persistent storage to allocate for
    the proto-BOSH director, specified in megabytes.  Defaults to
    `40960`, or 40GB.


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

# Available Addons

- `alias` - Set up a local BOSH alias for this director.
  This reads the X.509 Certificate Authority Certificate from the
  vault, without bothering you for it, which can be quite handy.

- `login` - Authenticate to this director.  This sets up an alias
  in the process.  Administrator credentials are read from the
  vault automatically.

- `upload-stemcells` - Run through a nifty console wizard to
  choose the correct type (based on deployed CPI) and vintage
  (based on user selection) of stemcell, and automatically upload
  them to the new director.  This requires internet access, both
  from the jumpbox it gets executed on, and from the BOSH director
  itself.

  You can also specify one or more versions on the command line to skip
  the wizard, including specifying the latest minor version using the
  format of `<major>.latest`.  It will also take a `--fix` option to
  forcibly reinstall the stemcells.

- `runtime-config` - Generates a new runtime config with the
  ability to inject two new, local administrator accounts into
  each and every BOSH-deployed VM.  This will overwrite your
  existing runtime-config, without prompting, so be careful.

# Examples

Deploying BOSH director to vSphere

```
---
kit:
  name:    bosh
  version: 1.0.0
  features:
    - vsphere

params:
  env: acme-us-east-1-prod

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

Version 1.0.0 was the first version to support Genesis 2.6 hooks
for addon scripts and `genesis info`.
