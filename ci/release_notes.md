Minor upgrades to the kit for BOSH director/credhub/aws-cpi and small bump of Proto stemcell to 250.17.

# Migration

If you are upgrading from a version of this kit that uses bpm version `0.12.3`, or otherwise have bpm 0.12.3 uploaded as a release to the bosh director that deploys this kit, then please reference [GMP-BOSH-0001](https://genesisproject.io/docs/migrations/gmp-bosh-0001) when upgrading to this release.

# Known Issues

The uaa-release (v70) has a problem in this release with monit healthchecks when the HTTP (non-HTTPS) port is not enabled. To make uaa work with this release, add this override to your env file:

```
instance_groups:
- name: bosh
  jobs:
  - name: uaa
    properties:
      uaa:
        port: 8080
```

Be aware that this opens up a HTTP listener in addition to the HTTPS listener on 8443. BOSH will continue advertising the HTTPS listener as the login endpoint.

# Updates

**This release updates the following:**

* BOSH director to 268.7.0
* Credhub to 2.1.5
* bosh-aws-cpi to 74
* Proto stemcell to 250.17
