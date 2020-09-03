BOSH Genesis Kit
==================

This is a Genesis Kit for deploying [BOSH][1]. It will allow
you to deploy BOSH via `bosh create-env` style deployments,
as well as deploy BOSH on top of another BOSH similarly to how
most other things are deployed on BOSH.

Quick Start
-----------

To use it, you don't even need to clone this repository!  Just run
the following (using Genesis v2):

```shell
# create a bosh-deployments repo using the latest version of the bosh kit
genesis init --kit bosh

# create a bosh-deployments repo using v1.0.0 of the bosh kit
genesis init --kit bosh/1.0.0

# create a my-bosh-configs repo using the latest version of the bosh kit
genesis init --kit bosh -d my-bosh-configs
```

Learn More
----------

For more in-depth documentation, check out the [manual][2].

[1]: https://bosh.io
[2]: MANUAL.md
