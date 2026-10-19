# OCFP GCP BOSH kit compatibility

Branch: `ocfp-gcp`, based on `develop`. Worktree:
`work/kits/bosh/ocfp-gcp`. Parent authority is the CLI worktree plan
`work/clis/ocfp/aws-gcp-provider-parity/plans/aws-gcp-provider-parity.md`.
No live deployment or commit/merge before review. Eventual target: develop.

## Design and progress

- [x] Inspect actual blueprint dispatch and canonical CLI exports.
- [x] TDD blueprint selection for gcp/google aliases in OCFP mgmt and ocf.
- [x] Add canonical GCP base/mgmt/ocf mapping of project, JSON credentials,
  physical zone, network/subnetwork, tags, private addressing and disk sizing.
- [x] Wire native GCS director/agent JSON credentials and bucket variables;
  retain explicit internal blobstore option. Never synthesize AWS IAM values.
- [x] Verify template contract with offline fixtures and the real blueprint.
- [x] Run available kit regression checks, document deferred live acceptance.

Adversarial findings: current `ocfp/gcp/meta.yml` is stale and is not selected
by the blueprint; required `ocfp/gcp/base.yml` does not exist. The blueprint
recognizes google while kit supports names gcp. Canonicalize dispatch locally
without renaming public CPI release names. Do not merely dual-write missing
Vault records: that cannot supply missing manifests or valid GCS credentials.
Shared CLI exports must keep physical zone distinct from logical AZ alias.

## Review and validation

Real blueprint selection passes for gcp/google, mgmt/ocf, internal/external.
Native GCP variable adapters evaluate with graft, then feed the vendored GCP
CPI/GCS ops through `bosh interpolate` with fixture credentials. Hook tests
exercise both aliases and network/VM/disk maps. The generic Genesis resolver
JSON-decodes Vault values; the CPI adapter restores serialized JSON before
entombment because google_cpi requires a JSON string. Canonical Vault reads
remain cpi/gcp even when kit.iaas is google; CPI config type is google.

The GCS ops already remove the internal blobstore. GCP does not load the
shared redundant remove-internal-blobstore graft file (which uses a singular
instance_group key). That existing file is outside this scoped change.

All validation is local: no Vault, CredHub, BOSH director or cloud calls.
Live acceptance remains deferred: deploy mgmt then ocf, upload cloud/CPI
configs, create/delete a VM+disk, upload/download a GCS blob, and verify
private routing and firewall tags. Credentials need GCE and GCS authority;
this change does not manufacture service-account keys or IAM bindings.

Verified base: `git merge-base HEAD develop` equals develop commit
`f5c09e2c824bd2637efae7e9b45995ba13b798fc`. Only BOSH kit source needed for
this director/CPI/cloud-config integration; no other kit files were changed.
Adversarial review added Shared VPC host-project preservation independently
of the service project, with fixture assertions. Current offline suite:
308 assertions in four test files, all passing. The management graft overlay
also preserves the upstream subnet range/gateway in the actual merger.

Broader offline regression: `prove spec/unit/*.t spec/ocfp-gcp.t
spec/ocfp-gcp-config.t spec/ocfp-gcp-manifest.t
spec/blacksmith-credhub-client.t` passed all 389 assertions in 10 files,
including existing PVE CPI/property/storage and cloud AZ mapping regressions.
The deployment golden suite `spec/spec.t` requires the Genesis validator
harness and is not represented as executed by these standalone checks.

## Completion

Implementation and independent review are complete. Offline validation passed
389 assertions across 10 files; `git diff --check` passed. Functional changes
and documentation are separate atomic commits. Branch remains `ocfp-gcp`,
based on `develop`; no merge, push or live deployment was performed.
