BOSH Genesis Kit
==================

This is a Genesis Kit for deploying [BOSH][1]. It will allow
you to deploy BOSH via `bosh create-env` style deployments,
as well as deploy BOSH on top of another BOSH similarly to how
most other things are deployed on BOSH.

Quick Start
-----------

To use it, you don't even need to clone this repository!  Just run
the following (using Genesis v2.8.12+):

```shell
# create a bosh-deployments repo using the latest version of the bosh kit
genesis init --kit bosh

# create a bosh-deployments repo using v3.0.5 of the bosh kit
genesis init --kit bosh/3.0.5

# create a my-bosh-configs repo using the latest version of the bosh kit
genesis init --kit bosh -d my-bosh-configs
```

Note: This kit is compatible with Genesis v3.1.0+ and provides enhanced functionality when used with Genesis v3.

Learn More
----------

For more in-depth documentation, check out the [manual][2].

Version History
--------------

### v3.0.5
- Added STACKIT as a supported IaaS provider
- Refactored hooks and updated configuration for OpenStack CPI
- Improved error handling in the terminate hook

### v3.0.4
- Added support for OpenStack compatible IaaS providers
- Improved database integration options
- Enhanced OCFP reference architecture support
- Updated to latest upstream bosh-deployment components

### v3.0.0
- Major version upgrade with Genesis v3 compatibility
- Streamlined deployment process for both proto-BOSH and regular BOSH directors
- Improved OCFP integration and reference architecture support
- Enhanced external database integration options
- Updated to use compiled releases for faster deployment

### v2.0.0
- Refactored to use upstream bosh-deployment repository
- Added print-env addon
- Added CredHub login and exodus support
- Improved migration path from v1.x series

### v1.0.0
- First version to support Genesis 2.6 hooks for addon scripts and `genesis info`

[1]: https://bosh.io
[2]: MANUAL.md
