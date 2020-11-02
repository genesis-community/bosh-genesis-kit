# Improvements

* Refactored runtime-config addon

  - Added suppport for BOSH DNS runtime, with parameters for whitelisting
    deployments (`params.dns_deployments_whitelist`, defaults to all) and
    enabling/disabling caching (`dns_cache`, defaults to true)
  - Set up features to generate passwords and certificates used by runtime
    config (`bosh-dns-healthcheck`, `netop-access`, `sysop-access`)
  - Separate runtimes into named configs (genesis.bosh-dns and
    genesis.ops-access), instead of merging with default runtime config.

* In `genesis new` wizard, allow domain to be used for vCenter location

# Bug Fixes

* Fix missing genesis.bosh_env in new hook

# Upstream Tracking

* Now based on bosh-deployment commit #caef64f
