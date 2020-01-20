# Changed Features

* Changed `azure-registry` to `registry` due to AWS, Google, and OpenStack 
  adding support for this as well. Enabling this feature will include the BOSH 
  registry on the deployment. This can be used if you need to maintain or 
  roll-forward deployments using stemcells on CPI API version 1.

# Software Updates

- Updated BOSH to 270.10.0 from 270.9.0
- Updated BPM to 1.1.6 from 1.1.5
- Updated AWS CPI to 80 from 79
- Updated Google CPI to 30.0.0 from 29.0.1
- Updated vSphere CPI to 53.0.5 from 53.0.3
- Updated Stemcells for Proto BOSHes to 621.41 from 621.26

# BOSH Director Components

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| bosh | [270.10.0](https://github.com/cloudfoundry/bosh/releases/tag/v270.10.0) | 6 December 2019 |
| bpm | [1.1.6](https://github.com/cloudfoundry/bpm-release/releases/tag/v1.1.6) | 5 December 2019 |
| uaa | [74.12.0](https://github.com/cloudfoundry/uaa-release/releases/tag/v74.12.0) | 02 December 2019 |
| credhub | [2.5.9](https://github.com/pivotal-cf/credhub-release/releases/tag/2.5.9) | 26 November 2019 |

# Cloud Provider Interfaces

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| bosh-azure-cpi | [37.0.0](https://github.com/cloudfoundry/bosh-azure-cpi-release/releases/tag/v37.0.0) | 18 October 2019 |
| bosh-google-cpi | [30.0.0](https://github.com/cloudfoundry/bosh-google-cpi-release/releases/tag/v30.0.0) | 12 December 2019 |
| bosh-aws-cpi | [80](https://github.com/cloudfoundry/bosh-aws-cpi-release/releases/tag/v80) | 7 January 2020 |
| bosh-vsphere-cpi | [53.0.5](https://github.com/cloudfoundry/bosh-vsphere-cpi-release/releases/tag/v53.0.5) | 10 January 2020 |
| bosh-openstack-cpi | [44](https://github.com/cloudfoundry/bosh-openstack-cpi-release/releases/tag/v44) | 20 November 2019 |
| bosh-warden-cpi | [41](https://github.com/cppforlife/bosh-warden-cpi-release/releases/tag/v41) | 18 July 2018 |
| garden-runc | [1.19.9](https://github.com/cloudfoundry/garden-runc-release/releases/tag/v1.19.9) | 21 November 2019 |

# Extras

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| port-forwarding | [6](https://github.com/cloudfoundry-community/port-forwarding-boshrelease/releases/tag/v6) | 26 July 2016 |
| os-conf | [21.0.0](https://github.com/cloudfoundry/os-conf-release/releases/tag/v21.0.0) | 4 September 2019 |
