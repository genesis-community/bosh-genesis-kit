# Improvements

* Addon `upload-stemcells` can now download the selected stemcells to the
  local machine then upload the local copy to the bosh director using the --dl
  option.  While remote upload is preferred, this is necessary when the
  director does not have direct internet access.

* Addon `upload-stemcells` can be run with a --dry-run flag that will show the
  details for the selected or specified stemcells, but won't actually upload.

* New addon `download-stemcells` was added to download stemcells for later
  uploading, such as with an air-gapped environment.  Behaves the same way as
  `upload-stemcells`, but writes the stemcell archives to the current
  directory.

* Addon `upload-stemcells` can take stemcell archive files as arguments so the
  previously download files can be uploaded en masse.

* Improved output of the `info` addon to give more accurate instructions when
  the path or executible was not the defaults.

* Improved the output of hooks for `post-deploy`, `check` and the list from
  `addon`

* Any output providing an executable genesis call will now be accurate from
  the directory the command providing them was run in.  Before, it just stated
  `genesis ...` but now it takes into consideration the name and path of your
  Genesis executable, and any -C option needed to reference the environment
  file.

# Genesis v2.7.x Deprecations

* Kit now requires a minimum Genesis version of 2.7.6

* Removed certificate CN/SAN checks from the `check` hook, as Genesis now
  performs these prior to deploy, so no need to duplicate.

* Replaced references to `params.env` with updated references: `genesis.env`
  in manifest fragments, and `$GENESIS_ENVIRONMENT` in hooks scripts.

# Bug Fixes

* Fixed bugs in upload-stemcells introduced in v1.10.1

* Fixed some remaining deprecations that caused Genesis v2.7.x to fail if an
  alterative secrets mount was in use.

# Requirements

* This kit requires Genesis v2.7.6-rc1 or higher

# BOSH Director Components

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| bosh | [270.12.0](https://github.com/cloudfoundry/bosh/releases/tag/v270.12.0) | 26 February 2020 |
| bpm | [1.1.7](https://github.com/cloudfoundry/bpm-release/releases/tag/v1.1.7) | 10 February 2020 |
| uaa | [74.15.0](https://github.com/cloudfoundry/uaa-release/releases/tag/v74.15.0) | 2 March 2020 |
| credhub | [2.5.11](https://github.com/pivotal-cf/credhub-release/releases/tag/2.5.11) | 30 January 2020 |

# Cloud Provider Interfaces

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| bosh-azure-cpi | [37.2.0](https://github.com/cloudfoundry/bosh-azure-cpi-release/releases/tag/v37.2.0) | 23 January 2020 |
| bosh-google-cpi | [30.0.0](https://github.com/cloudfoundry/bosh-google-cpi-release/releases/tag/v30.0.0) | 12 December 2019 |
| bosh-aws-cpi | [82](https://github.com/cloudfoundry/bosh-aws-cpi-release/releases/tag/v82) | 6 March 2020 |
| bosh-vsphere-cpi | [53.0.9](https://github.com/cloudfoundry/bosh-vsphere-cpi-release/releases/tag/v53.0.9) | 6 March 2020 |
| bosh-openstack-cpi | [44](https://github.com/cloudfoundry/bosh-openstack-cpi-release/releases/tag/v44) | 20 November 2019 |
| bosh-warden-cpi | [41](https://github.com/cppforlife/bosh-warden-cpi-release/releases/tag/v41) | 18 July 2018 |
| garden-runc | [1.19.10](https://github.com/cloudfoundry/garden-runc-release/releases/tag/v1.19.10) | 22 January 2020 |

# Extras

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| port-forwarding | [6](https://github.com/cloudfoundry-community/port-forwarding-boshrelease/releases/tag/v6) | 26 July 2016 |
| os-conf | [21.0.0](https://github.com/cloudfoundry/os-conf-release/releases/tag/v21.0.0) | 4 September 2019 |
| vault-credhub-proxy | [1.1.9](https://github.com/starkandwayne/vault-credhub-proxy-release/releases/tag/v1.1.9) | 16 April 2020 |
