# Release Changes

* BOSH bumped to 269.0.1 from 268.6.0
* BPM bumped to 1.0.4 from 0.12.3
* UAA bumped to 73.0.0 from 70.0
* Credhub bumped to 2.4.0 from 2.1.2
* AWS CPI bumped to 74 from 73
* VSphere CPI bumped to 52.1.1 from 52.1.0
* Garden RunC bumped to 1.19.1 from 1.18.3

# Bug Fixes

* Fixed version-sha1 mismatch on AWS CPI.
* The previous bug of monit not being able to determine if UAA was successfully
  running was fixed by the UAA team by implementing a localhost-only HTTP listening
  port.

# Core Components

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| bosh | [269.0.1](https://github.com/cloudfoundry/bosh/releases/tag/v269.0.1) | May 8, 2019 |
| bpm | [1.0.4](https://github.com/cloudfoundry-incubator/bpm-release/releases/tag/v1.0.4) | Apr 1, 2019 |
| uaa | [73.0.0](https://github.com/cloudfoundry/uaa-release/releases/tag/v73.0.0) | May 14, 2019 |
| credhub | [2.4.0](https://github.com/pivotal-cf/credhub-release/releases/tag/2.1.2) | May 2, 2019 |
| bosh-azure-cpi | [35.5.0](https://github.com/cloudfoundry/bosh-azure-cpi-release/releases/tag/v35.5.0) | Nov 5, 2018 |
| bosh-google-cpi | [29.0.1](https://github.com/cloudfoundry/bosh-google-cpi-release/releases/tag/v29.0.1) | Feb 10, 2019 |
| bosh-aws-cpi | [74](https://github.com/cloudfoundry/bosh-aws-cpi-release/releases/tag/v74) | Mar 14, 2019 |
| bosh-vsphere-cpi | [52.1.1](https://github.com/cloudfoundry/bosh-vsphere-cpi-release/releases/tag/v52.1.1) | May 12, 2019 |
| bosh-openstack-cpi | [42](https://github.com/cloudfoundry/bosh-openstack-cpi-release/releases/tag/v42) | Jan 28, 2019 |
| bosh-warden-cpi | [41](https://github.com/cppforlife/bosh-warden-cpi-release/releases/tag/v41) | Jul 18, 2018 |
| garden-runc | [1.19.1](https://github.com/cloudfoundry/garden-runc-release/releases/tag/v1.19.1) | Mar 25, 2019 |
| port-forwarding | [6](https://github.com/cloudfoundry-community/port-forwarding-boshrelease/releases/tag/v6) | Jul 26, 2016 |
| os-conf | [20](https://github.com/cloudfoundry/os-conf-release/releases/tag/v20) | Aug 10, 2018 |
