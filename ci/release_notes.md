This release updates several of the core components and BOSH CPIs.

# New Features

- BOSH will now resize underlying VM disks via the CPI (if
  supported), rather than going through the costly process of
  provisioning a new disk and copying the data over to it via the
  operating system.

- This release now targets the Ubuntu Xenial stemcell series,
  starting on 97.x.  Xenial Xerus 16.04 is a Canonical LTS
  release, and will continue to receive security updates through
  April of 2021.  Trusty Tahr 14.04 is EOL as of April 2019.

- The default `bosh_vm_type` has changed from `small` to `large`.
  If you deployed BOSH using the defaults, upgrading to this kit
  version will incur a rebuild of the BOSH VM.

# Core Components

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| bosh | [268.1.0](https://github.com/cloudfoundry/bosh/releases/tag/v268.1.0) | 27 September 2018 |
| bpm (new) | [0.12.3](https://github.com/cloudfoundry-incubator/bpm-release/releases/tag/v0.12.3) | 10 September 2018 |
| uaa | [60.2](https://github.com/cloudfoundry/uaa-release/releases/tag/v60.2) | 19 July 2018 |
| credhub | [2.0.2](https://github.com/pivotal-cf/credhub-release/releases/tag/2.0.2) | 09 August 2018 |
| bosh-azure-cpi | [35.4.0](https://github.com/cloudfoundry/bosh-azure-cpi-release/releases/tag/v35.4.0) | 14 August 2018 |
| bosh-google-cpi | [27.0.1](https://github.com/cloudfoundry/bosh-google-cpi-release/releases/tag/v27.0.1) | - |
| bosh-aws-cpi | [72](https://github.com/cloudfoundry/bosh-aws-cpi-release/releases/tag/v72) | 31 July 2018 |
| bosh-vsphere-cpi | [50](https://github.com/cloudfoundry/bosh-vsphere-cpi-release/releases/tag/v50) | 08 June 2018 |
| bosh-openstack-cpi | [39](https://github.com/cloudfoundry/bosh-openstack-cpi-release/releases/tag/v39) | 06 July 2018 |
| bosh-warden-cpi | [40](https://github.com/cppforlife/bosh-warden-cpi-release/releases/tag/v40) | 28 March 2018 |
| garden-runc | [1.6.0](https://github.com/cloudfoundry/garden-runc-release/releases/tag/v1.6.0) | 03 May 2017 |
| port-forwarding | [6](https://github.com/cloudfoundry-community/port-forwarding-boshrelease/releases/tag/v6) | 26 July 2016 |
| os-conf | [20](https://github.com/cloudfoundry/os-conf-release/releases/tag/v20) | - |
