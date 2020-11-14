# Improvements

* In `genesis new` wizard, allow domain to be used for vCenter location

* Refactored runtime-config addon

  - Added suppport for BOSH DNS runtime, with parameters for whitelisting
    deployments (`params.dns_deployments_whitelist`, defaults to all) and
    enabling/disabling caching (`dns_cache`, defaults to true)

  - Set up features to generate passwords and certificates used by runtime
    config (`bosh-dns-healthcheck`, `netop-access`, `sysop-access`)

  - Separate runtimes into named configs (genesis.bosh-dns and
    genesis.ops-access), instead of merging with default runtime config.

# Bug Fixes

* Fix missing genesis.bosh_env in new hook

* You can now specify default features to fix the order they are applied,
  which may be required for some combination of features.

# Upstream Tracking

* Now based on bosh-deployment commit [#f518c39](https://github.com/cloudfoundry/bosh-deployment/tree/f518c397cae6032dcfec1fd42d884090bb70e4bf)
