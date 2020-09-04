# Major Refactor: v2.0.0

Version v2.0.0 starts a new era based on the upstream [bosh-deployment](https://github.com/cloudfoundry/bosh-deployment) repository as the de facto community standard.  Of course, being Genesis, it continues to  embed best practices for deployments, including all the features and addons
you used in v1.x series.

Additional features are:

* Use compiled releases to significantly speed up proto-BOSH deployment.
* Ability to specify the upstream bosh-deployment ops files as Genesis features
* Ability to spin your own features local to your deployment repository, in either ops or overlay (spruce) format
* Use bosh variables in the enviornment file instead of on the command line, by just putting them under the `bosh-variables:` top-level key.

There are many changes available, so it is recommended to consult the `MANUAL.md` file.

# Upgrading

You will need to be upgraded to v1.15.2 first.  Make sure you back up your systems, and test on a sandbox or scratch environment first.  As proto-BOSH environments don't give you the option to review and approve changes to the deploy, you can generate the manifest with `genesis manifest <env>` and compare it to the last deployed manifest in your deployment repos cache at `.genesis/manifests/<env>.yml` 

If you need help, please contact us in the [Genesis Slack channel](https://genesisproject.io/community/)

# Embedded Upstream `bosh-deployment` 

* Version: [4a2ab9e](https://github.com/cloudfoundry/bosh-deployment/tree/4a2ab9e)
* Embedded: 2020-Aug-15 00:53:46 UTC

# BOSH Director Components

| Release | Version | Release Date | Type |
| ------- | ------- | ------------ | ---- |
| bosh | [271.2.0](https://github.com/cloudfoundry/bosh/releases/tag/v271.2.0) | 03 August 2020 | compiled: ubuntu-xenial@621.78<br>source |
| bpm | [1.1.8](https://github.com/cloudfoundry/bpm-release/releases/tag/v1.1.8) | 23 March 2020 | compiled: ubuntu-xenial@621.78<br>source |
| credhub | [2.8.0](https://github.com/pivotal/credhub-release/releases/tag/2.8.0) | 22 July 2020 | compiled: ubuntu-xenial@621.78<br>source |
| node-exporter | [4.2.0](https://github.com/bosh-prometheus/node-exporter-boshrelease/releases/tag/v4.2.0) | 29 August 2019 | source |
| uaa | [74.23.0](https://github.com/cloudfoundry/uaa-release/releases/tag/v74.23.0) | 15 July 2020 | compiled: ubuntu-xenial@621.78<br>source |
| vault-credhub-proxy | [1.1.9](https://github.com/starkandwayne/vault-credhub-proxy-release/releases/tag/v1.1.9) | 16 April 2020 | source |


# Cloud Infrastructure Interfaces

| Release | Version | Release Date | Type |
| ------- | ------- | ------------ | ---- |
| bosh-aws-cpi | [83](https://github.com/cloudfoundry/bosh-aws-cpi-release/releases/tag/v83) | 20 July 2020 | source |
| bosh-azure-cpi | [37.3.0](https://github.com/cloudfoundry/bosh-azure-cpi-release/releases/tag/v37.3.0) | 10 August 2020 | source |
| bosh-google-cpi | [30.0.0](https://github.com/cloudfoundry/bosh-google-cpi-release/releases/tag/v30.0.0) | 12 December 2019 | source |
| bosh-openstack-cpi | [44](https://github.com/cloudfoundry/bosh-openstack-cpi-release/releases/tag/v44) | 20 November 2019 | source |
| bosh-vsphere-cpi | [54.1.0](https://github.com/cloudfoundry/bosh-vsphere-cpi-release/releases/tag/v54.1.0) | 11 June 2020 | source |
| bosh-warden-cpi | [41](https://github.com/cppforlife/bosh-warden-cpi-release/releases/tag/v41) | 18 July 2018 | compiled: ubuntu-xenial@621.78 |
| garden-runc | [1.19.16](https://github.com/cloudfoundry/garden-runc-release/releases/tag/v1.19.16) | 07 August 2020 | compiled: ubuntu-xenial@621.78 |
| os-conf | [22.0.0](https://github.com/cloudfoundry/os-conf-release/releases/tag/v22.0.0) | 25 March 2020 | source |
