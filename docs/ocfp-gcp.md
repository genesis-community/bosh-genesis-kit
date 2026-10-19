# OCFP on Google Cloud

Use `kit.iaas: gcp` (the `google` alias is also accepted) with the `ocfp`
feature. Bootstrap and populate Vault with the matching OCFP CLI before
building a management or workload director. This kit consumes the canonical
`cpi/gcp`, `net`, `net/subnets`, `net/sgs`, and `bosh/blobstores/bosh` records.
The management director uses the observed physical zone; workload directors
use the generated cloud configuration and logical availability zone.

The native Google CPI requires `cpi/gcp:project` and a serialized service
account JSON key at `cpi/gcp:json_key`. A locally available ADC identity does
not automatically supply a transferable key to a remote CPI. Provision the
remote credential explicitly with the required GCE and GCS permissions.
No AWS access keys are synthesized or consumed.

External blobstore is native GCS by default. `+internal-blobstore` retains
the director's internal blobstore and does not read GCS bucket variables.
The external bucket comes from `bosh/blobstores/bosh:bucket_name`; the CPI
JSON key also supplies director and agent GCS authentication.

Director VMs default to private addresses and require existing egress.
For create-env only, `params.ephemeral_external_ip: true` requests an ephemeral
public address. Root disks default to 40 GiB `pd-balanced`; machine type
defaults to `e2-standard-2`, configurable through the existing google params.
Generated workload VM types use e2-standard-2 (dev) or e2-standard-4 (prod).

Shared VPC host identity comes from `net:project`, independently of the
service project in `cpi/gcp:project`. Both create-env networking and generated
cloud config pass `xpn_host_project_id` to the Google CPI. Workload subnets
use their exported `cloud_name`, and firewall membership uses actual network
tags exported under `net/sgs`, rather than resource numeric IDs.

Offline checks:

```sh
prove spec/ocfp-gcp.t spec/ocfp-gcp-config.t spec/ocfp-gcp-manifest.t
```

These validate selection, native mappings, and fixture interpolation; they
do not establish live deployment compatibility. Live acceptance includes
management/workload deployment, CPI disk lifecycle, GCS access and private
routing, and remains deferred for this change.
