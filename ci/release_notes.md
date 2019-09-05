# Software Updates

-	Updated BOSH to 270.5.0 from 268.6.0
- Updated BPM to 1.1.3 from 1.0.4
- Updated UAA to 74.0.0 from 73.0.0
- Updated Credhub to 2.5.2 from 2.4.0
- Updated Garden RunC to 1.19.6 from 1.19.1
- Updated AWS CPI to 77 from 74
- Updated Azure CPI to 36.0.1 from 35.5.0
- Updated Openstack CPI to 43 from 42
- Updated vSphere CPI to 53.0.1 from 52.1.1

# Upgrading

This release bumps to BOSH 270+, which dropped support for v1 style deployment manifests.
In Genesis, we have occasionally used the old `persistent_disk_pool` key instead of the
newer `persistent_disk_type`. If your manifest suffers from this, this version of BOSH
will err. We are releasing versions of the affected kits with the fix.

# BOSH Director Components

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| bosh | [270.5.0](https://github.com/cloudfoundry/bosh/releases/tag/v270.5.0) | 12 August 2019 |
| bpm | [1.1.3](https://github.com/cloudfoundry/bpm-release/releases/tag/v1.1.3) | 14 August 2019 |
| uaa | [74.0.0](https://github.com/cloudfoundry/uaa-release/releases/tag/v73.0.0) | 07 August 2019 |
| credhub | [2.5.3](https://github.com/pivotal-cf/credhub-release/releases/tag/2.5.3) | 04 September 2019 |


# Cloud Provider Interfaces

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| bosh-azure-cpi | [36.0.1](https://github.com/cloudfoundry/bosh-azure-cpi-release/releases/tag/v36.0.1) | 11 June 2019 |
| bosh-google-cpi | [29.0.1](https://github.com/cloudfoundry/bosh-google-cpi-release/releases/tag/v29.0.1) | 11 February 2019 |
| bosh-aws-cpi | [77](https://github.com/cloudfoundry/bosh-aws-cpi-release/releases/tag/v77) | 12 August 2019 |
| bosh-vsphere-cpi | [53.0.1](https://github.com/cloudfoundry/bosh-vsphere-cpi-release/releases/tag/v53.0.1) | 31 July 2019 |
| bosh-openstack-cpi | [43](https://github.com/cloudfoundry/bosh-openstack-cpi-release/releases/tag/v43) | 10 June 2019 |
| bosh-warden-cpi | [41](https://github.com/cppforlife/bosh-warden-cpi-release/releases/tag/v41) | 18 July 2018 |
| garden-runc | [1.19.6](https://github.com/cloudfoundry/garden-runc-release/releases/tag/v1.19.6) | 04 September 2019 |

# Extras
| port-forwarding | [6](https://github.com/cloudfoundry-community/port-forwarding-boshrelease/releases/tag/v6) | 26 July 2016 |
| os-conf | [20](https://github.com/cloudfoundry/os-conf-release/releases/tag/v20) | 10 August 2018 |
