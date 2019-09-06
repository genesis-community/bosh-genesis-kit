# Major Change

Consul is no longer supported, and has been removed from this release.  While
replacing consul with BOSH DNS was optional since v1.3.0 using the feature
`migrate-1.3-without-consul`, that feature has now been permanently turned on.

You should be able to directly upgrade to this version with no impact to your
existing Cloud Foundry system, it is recommended that you validate it by
upgrading to v1.4.1 with the `migrate-1.3.1-without-consul` so that if
something does occur, you can redeploy without that feature.

**Note**: You must [enable BOSH DNS](https://bosh.io/docs/dns/#enable) in your BOSH deployment and add it to  your
runtime config [(example)](https://github.com/cloudfoundry/bosh-deployment/blob/master/runtime-configs/dns.yml) to deploy this version.

# BOSH v270+ Fix

This release cleans up BOSH v1 manifest keys that can prevent deployment with
v270+ BOSH directors.

# Core Components

This is the list of core components used in this release.  No core components were updated, added or removed since last release.

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| bosh-dns-aliases | [0.0.3](https://github.com/cloudfoundry/bosh-dns-aliases-release/releases/tag/v0.0.3) | 24 October 2018 |
| bpm | [0.13.0](https://github.com/cloudfoundry-incubator/bpm-release/releases/tag/v0.13.0) | 12 October 2018 |
| capi | [1.70.0](https://github.com/cloudfoundry/capi-release/releases/tag/1.70.0) | 03 October 2018 |
| cf-networking | [2.17.0](https://github.com/cloudfoundry/cf-networking-release/releases/tag/2.17.0) | 09 October 2018 |
| cf-smoke-tests | [40.0.5](https://github.com/cloudfoundry/cf-smoke-tests-release/releases/tag/40.0.5) | 17 May 2018 |
| cflinuxfs2 | [1.242.0](https://github.com/cloudfoundry/cflinuxfs2-release/releases/tag/v1.242.0) | 12 October 2018 |
| cflinuxfs3 | [0.51.0](https://github.com/cloudfoundry/cflinuxfs3-release/releases/tag/v0.51.0) | 22 January 2019 |
| cf-syslog-drain | [7.1](https://github.com/cloudfoundry/cf-syslog-drain-release/releases/tag/v7.1) | 13 September 2018 |
| consul | [193](https://github.com/cloudfoundry-incubator/consul-release/releases/tag/v193) | 30 May 2018 |
| diego | [2.19.0](https://github.com/cloudfoundry/diego-release/releases/tag/v2.19.0) | 11 October 2018 |
| garden-runc | [1.18.3](https://github.com/cloudfoundry/garden-runc-release/releases/tag/v1.18.3) | 18 Febuary 2018 |
| loggregator | [104.0](https://github.com/cloudfoundry/loggregator-release/releases/tag/v104.0) | 01 October 2018 |
| loggregator-agent | [2.3](https://github.com/cloudfoundry/log-cache-release/releases/tag/v2.3) | - |
| log-cache | [2.0.2](https://github.com/cloudfoundry/log-cache-release/releases/tag/v2.0.2) | 20 November 2018 |
| nats | [26](https://github.com/cloudfoundry/nats-release/releases/tag/v26) | 02 October 2018 |
| routing | [0.182.0](https://github.com/cloudfoundry/routing-release/releases/tag/0.182.0) | 19 September 2018 |
| silk | [2.17.0](https://github.com/cloudfoundry/silk-release/releases/tag/2.17.0) | 09 October 2018 |
| statsd-injector | [1.4.0](https://github.com/cloudfoundry/statsd-injector-release/releases/tag/v1.4.0) | 26 September 2018 |
| uaa | [62.0](https://github.com/cloudfoundry/uaa-release/releases/tag/v62.0) | 03 October 2018 |
| nfs-volume | [1.0.7](https://github.com/cloudfoundry/nfs-volume-release/releases/tag/v1.0.7) | 24 August 2017 |
| postgres | [3.1.5](https://github.com/cloudfoundry-community/postgres-boshrelease/releases/tag/v3.1.5) | 30 January 2019 |
| haproxy | [9.3.0](https://github.com/cloudfoundry-incubator/haproxy-boshrelease/releases/tag/v9.3.0) | 24 August 2018

# Buildpacks

This is the list of buildpacks provided with this release.  No buildpacks were updated, added or removed since last release.

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| binary | [1.0.31](https://github.com/cloudfoundry/binary-buildpack/releases/tag/v1.0.31) | 04 March 2019 |
| dotnet-core | [2.1.5](https://github.com/cloudfoundry/dotnet-core-buildpack/releases/tag/v2.1.5) | 21 September 2018 |
| go | [1.8.28](https://github.com/cloudfoundry/go-buildpack/releases/tag/v1.8.28) | 12 October 2018 |
| java | [4.16.1](https://github.com/cloudfoundry/java-buildpack/releases/tag/v4.16.1) | 17 October 2018 |
| nodejs | [1.6.32](https://github.com/cloudfoundry/nodejs-buildpack/releases/tag/v1.6.32) | 13 September 2018 |
| php | [4.3.61](https://github.com/cloudfoundry/php-buildpack/releases/tag/v4.3.61) | 13 September 2018 |
| python | [1.6.21](https://github.com/cloudfoundry/python-buildpack/releases/tag/v1.6.21) | 24 August 2018 |
| ruby | [1.7.24](https://github.com/cloudfoundry/ruby-buildpack/releases/tag/v1.7.24) | 12 October 2018 |
| staticfile | [1.4.32](https://github.com/cloudfoundry/staticfile-buildpack/releases/tag/v1.4.32) | 10 September 2018 |
