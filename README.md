Cloud Foundry Genesis Kit
==================

This is a Genesis Kit for the [Cloud Foundry][1]. It will deploy
a Cloud Foundry environment, loosely based off of [cf-deployments][2].

Quick Start
-----------

To use it, you don't even need to clone this repository!  Just run
the following (using Genesis v2):

```
# create a cf-deployments repo using the latest version of the cf kit
genesis init --kit cf

# create a cf-deployments repo using v1.0.0 of the cf kit
genesis init --kit cf/1.0.0

# create a my-cf-configs repo using the latest version of the cf kit
genesis init --kit cf -d my-cf-configs
```

Subkits
-------

Cloud Foundry can be deployed with a large number of variations depending
on the environment it is deployed to. There are options for database
backends, blobstore providers, and enabling special features.

#### Database Backends

Currently, this kit offers the following options for providing the databases
for the Cloud Controller, UAA, and Diego:

- **db-external-mysql** - Use this if you have an external service (like RDS)
  providing MySQL databases for CC/UAA/Diego.
- **db-external-postgres** - Use this if you have an external service (like RDS)
  providing Postgres databases for CC/UAA/Diego.
- **db-internal-postgres** - Use this if you don't have any external services to
  provide the CF databases. This is currently a single-point-of-failure node, so
  any updates to it will interrupt access to CC/UAA, and may affect Diego's ability
  to stage apps + recover failing instances.

#### Blobstore Backends

Cloud Foundry uses a blobstore to store artifacts for app packages, droplets, buildpacks,
and resource pools. This kit supports the following blobstore backends:

- **blobstore-s3** - Uses an AWS S3 bucket to provide CF with its blobstore.
- **blobstore-azure** - Uses Azure Storage to provide CF with its blobstore.
- **blobstore-gcp** - Uses Google Cloud Storage to provide CF with its blobstore.
- **blobstore-webdav** - Adds a single-point-of-failure `blobstore` VM to the deployment,
  running webdav to provide the blobstore.

#### HAProxy Frontends

Depending on your infrastructure and requirements, you may wish to add an HAProxy
layer in front of your cloud foundry. Here are some of the reasons you may wish to
do so:

- You need SNI support, but your infrastructure cannot support it
- You do not have a layer-7 (HTTP aware) load balancer
- You need to support WebSockets on port 443
- You wish to prevent public access to certain internal-only domains that are hosted
  by Cloud Foundry

These are the following supported HAProxy configurations this kit provides for CF:

- **omit-haproxy** - Don't use haproxy at all.
- **haproxy-notls** - Enable HAProxy, but it will not be terminating SSL connections.
  Use this if you want HAProxy, and terminate SSL upstream at an IaaS load balancer
- **haproxy-tls** - Enable HAProxy, and it will terminate SSL connections. If using
  this, ensure your IaaS load balancer is set to TCP mode. This may result in not knowing
  what originating IP the request comes from, depending on how the IaaS load balancers
  work (since the IaaS won't be setting X-Forwarded-For in TCP mode).

#### NFS Volume Services

Cloud Foundry now has support for Volume Services. Applying this subkit will
enable the NFS Volume Services driver on your `cell` nodes, allowing apps
to be connected with services that provide NFS mounts for persistent storage.

#### Minimum VMs

This subkit reduces the footprint of Cloud Foundry to a bare minimum. It loses
HA capabilities, but could be ideal for a budget-conscious development environment.

#### Azure

If deploying on Azure, this subkit will be useful, as it replaces the default
Availability Zones with just `z1`, to make the cloud config simpler, as Azure
uses Availability sets. This also includes VM extensions for jobs to allow
you to explicitly name the Azure availability sets for each job, in your Cloud Config.

However, the most important functionality of this subkit is that it enables the
`cell` nodes to detect what Fault Domain they are running on, and use that information
for application anti-affinity, to keep multi-instance apps running on different Fault
Domains.

#### SHIELD

If specified, this will add the SHIELD agent to the `postgres` node, and `blobstore` node,
if those VMs are being used in the deployment. This is done by detecting if the
`db-internal-postgres` and `blobstore-webdav` subkits are enabled in conjunction with
`shield`. If so, the `shield-dbs` and `shield-blobstore` subkits will be added
to the configuration when generating a new environment yaml. If manually configuring
your environment from scratch, make sure you add those kits explicitly, if they apply.

Params
------

#### Base Params

- **params.base_domain** - Every Cloud Foundry needs domains. The base domain is used
  to provide a starting point for this. System-level components get namespaced into
  `*.system.<base_domain>`, and the default app domain is set to `run.<base_domain>`.
  For example, if the base domain is `bosh-lite.com`, the CF API can be found at
  `api.system.bosh-lite.com`, and the `cf-env` app would be pushed by default as
  `cf-env.run.bosh-lite.com`. However, this can be customized further with the
  `params.system_domain` (string) and `params.app_domain` (list) properties.
- **params.default_app_memory** - If not specified otherwise via `cf push`, `cf scale`,
  or the app manifest, new applications will be given this value as their memory
  limit. It starts at 256MB. If you are running lots of high-memory apps, consider
  increasing this, to make the lives of developers easier.
- **params.app_services_networks** - CF restricts what IPs applications can talk to.
  By default, only public access is allowed. If you have services internal to your
  VPC that apps will be communicating with, add the networks/hosts using CIDR notation
  as a list here. **NOTE** this will only control the initial values of these
  security groups, so changes to it may or may not take effect. Take a look at
  [cf deploy][3] for a more long-term mechanism to manage Application Security Groups.
  Alternatively, `cf security-groups` and `cf security-group` can be used to manually
  update the ASGs.
- **params.cf_public_ips** - To ensure that apps can talk to other apps via their public
  names, enter the public IPs of your Cloud Foundry (or the IPs of the load balancers
  that direct traffic to it). This property behaves similarly to `params.app_services_networks`,
  and changes will only take effect at the initial deploy.
- **params.skip_ssl_validation** - Enable this if your Cloud Foundry is using
  self-signed certificates, otherwise many components will be unable to communicate.
- **params.logger_port** - Allows you to specify what port the loggregator/doppler
  endpoint is listening on. Usually this is either 443 or 4443.

#### Blobstore Params

If you're using Azure, GCP, or S3 for your blobstore backend, you'll need to fill
out params defining how to authenticate to the storage API. Each of them require two
pieces of pre-shared information, using these param names:

- **params.gcp_sa_key**
- **params.gcp_sa_secret**
- **params.aws_access_key**
- **params.aws_access_secret**
- **params.azurerm_sa_name**
- **params.azurerm_sa_key**

If using the WebDAV blobstore, no additional parameters are required - it is configured
for you, with credentials

#### Database Params

If using `db-internal-postgres` subkit, you will not need to provide any additional
database-related params. However, if you are using either the external Postgres or
external MySQL subkits, you will need to provide the following information, to
point Cloud Foundry components at their databases:

- **params.ccdb_host** - Hostname/IP for the CC Database
- **params.ccdb_port** - Port for the CC Database
- **params.ccdb_user** - User to connect to the CC Database with
- **params.ccdb_password** - Password for to use with the above user (Stored in vault
  at `secret/path/to/env/cf/ccdb:password`)
- **params.diegodb_host** - Hostname/IP for the Diego Database
- **params.diegodb_port** - Port for the Diego Database
- **params.diegodb_user** - User to connect to the Diego Database with
- **params.diegodb_password** - Password for to use with the above user (Stored in vault
  at `secret/path/to/env/cf/diegodb:password`)
- **params.uaadb_host** - Hostname/IP for the UAA Database
- **params.uaadb_port** - Port for the UAA Database
- **params.uaadb_user** - User to connect to the UAA Database with
- **params.uaadb_password** - Password for to use with the above user (Stored in vault
  at `secret/path/to/env/cf/uaadb:password`)

#### HAProxy Params

When using HAProxy, either with or without TLS support, the following params
will be requested:

Furthermore, if using HAProxy with TLS, you will have these params available to you
as well:

- **params.disable_tls_10** - Disables TLS v1.0 in HAProxy
- **params.disable_tls_11** - Disables TLS v1.1 in HAProxy

**SSL PEM for Cloud Foundry**

In order to serve TLS connections, HAProxy needs
the SSL certificate + private key associated with it. This certificate should
be valid for `*.system.<base_domain>`, `*.run.<base_domain>`, and any other
vanity domains you wish to host in Cloud Foundry.

When creating a new environment, Genesis will prompt if you have a certificate
already generated + signed for your Cloud Foundry. If not, it can auto-create
a certificate valid for `*.system.<base_domain>` and `*.run.<base_domain>`. In
either case the combined cert/key PEM data can be found at
`secret/path/to/env/cf/haproxy/ssl:combined`.

If separate certificates are needed for custom org-specific or shared domains,
that is supported, but requires custom configuration to set
`properties.ha_proxy.ssl_pem` to a list of Vault paths which include the PEM
files for those certificates. You will want to add something like the following
to your environment YAML file:

```
properties:
  ha_proxy:
    ssl_pem:
    - (( vault meta.vault "/haproxy/ssl:combined" )) # Make sure to include the system/run .<base_domain> certificate
    - (( vault meta.vault "/haproxy/my-custom-cert:combined" )) # reference the path you've created in vault with the custom cert
```

#### Shield Params

- **params.shield_key_vault_path** - A Vault path to the SHIELD daemon's public SSH key
  This is used to authenticate the SHIELD daemon to the agent, when running tasks.

  For example: `secret/us/proto/shield/agent:public`

Cloud Config Requirements
-------------------------

#### Networking

`cf-genesis-kit` makes some assumptions about how your Cloud Foundry will be
deployed on the IaaS, to fit with the practices laid out in [Codex][4]. This
provides a basis for easily controlling network access between various CF components
using Network ACLs, as may be required by your organization. You
may need to adjust the `params.cf_*_network` properties to adjust for your
environment, or create the following networks in your Cloud Config:

- **cf-core** - This subnet is dedicated for the core components of Cloud
  Foundry. Everything that is not running applications, receiving external
  traffic, or providing the databases for CF goes here
- **cf-edge** - This subnet is dedicated to any components that directly receive
  public traffic, such as the `access`, `router`, and `haproxy` VMs.
- **cf-runtime** - Contains all the `cell` VMs
- **cf-db** - Contains the internal database VMs for Cloud Foundry, if present

#### VM Types

`cf-genesis-kit` shares VM types across a number of VMs that typically have
the same initial resource consumption. However, if necessary, it provides the
flexibility to customize the VM type for each `instance_group` being deployed,
via the `params.<instance_group_name>_vm_type` properties. Here are the built-in
VM Types used, and some suggestions for their sizing:

- **small** - Initially used by Consul, HAProxy, GoRouter, Doppler, BBS, SSH Proxy,
  and errands. We usually start with something with at least 1 CPU and 1GB of RAM.
- **medium** - Initially used by blobstore, UAA, API, Loggregator, and Diego,
  we usually start this VM type with at least 2 CPUs and 4GB of RAM.
- **large** - Initially used by the postgres node, if applicable for your env.
  Start with at least 2 CPUs and 8GB of RAM.
- **runtime** - Used for the Cell nodes, where applications run. Usually,
  these will be the biggest VMs in your deployment. You'll probably want
  to start with 4 CPUs and 16GB of RAM.

#### Disk Pools

`cf-genesis-kit` assumes that you will provide the following disk pools:

- **consul** - The Consul cluster for CF requires a small amount of persistent
  disk. 1GB is usually a safe value.
- **postgres** - If using the internal Postgres database to power Cloud Foundry,
  that VM will need a persistent disk pool. 10GB should be a safe bet for most
  environments.
- **blobstore** - If using the WebDAV blobstore, that VM will also need persistent
  disk. Start with 100GB, and scale up as needed.

#### Miscelaneous IaaS Needs

`cf-genesis-kit` requires at least two load balancers for proper functionality.
One is for the `router` VMs (or `haproxy` if used), to load balance inbound
http/https/wss traffic to your CF. The other is used to load balance across the
`access` VMs, to send Application SSH traffic directly to those nodes.

To attach load balancers to your VMs, the `cf-elb` and `ssh-elb` VM extensions
were provided, to use BOSH's cloud properties to attach the VMs to their corresponding
Load Balancers. In the event that your CPI does not auto-attach VMs to load
balancers, the `haproxy`, `router`, and `access` VMs are all configured with
static IPs, so they can be relied upon in manually configured Load Balancers.

When using the `azure` subkit, additional VM extensions are added (one per instance
group), to allow operators to specify the availability set names that each job will
use. Make sure that you define extensions for `<instance_group>_as` in your Cloud
Config. For example:

```
vm_extensions:
- name: consul_as
  cloud_properties:
   availability_set: us-west-prod-consul
```

Scaling
-------

As your CF workload grows, it will eventually become necessary to scale up, or scale
out your VMs. Scaling up can be accomplished by modifying your Cloud Config to have
VMs use bigger instances with more resources. You can additionally modify the
`params.<instance_group>_vm_type` properties in your deployment, to change their VM
Type in Cloud Config, if you wish to scale out only a subset of the instance groups
using `small`, or `medium`, for example.

To scale out, the `params.<instance_group>_instances` properties can be used to add
additional nodes of each type. There are a couple caveats to this:

- `params.consul_instances` must always be at least 3 nodes for HA. In order for the
  cluster to function properly in the event of the loss of an availability zone/fault
  domain, its instances should be spread evenly across three AZs/FDs. In order for
  quorum to be reached, and the cluster to function, there must be greater than 50%
  of the nodes still alive.
- Setting `params.blobstore_instances` and `params.postgres_instances` greater than 1
  does not help anything, as they are not clustered solutions, but single points of
  failure. These nodes must be scaled up, instead of out.

[1]: https://docs.cloudfoundry.org
[2]: https://github.com/cloudfoundry/cf-deployment
[3]: https://github.com/cloudfoundry-community/cf-plugin-deploy
[4]: https://github.com/starkandwayne/codex
