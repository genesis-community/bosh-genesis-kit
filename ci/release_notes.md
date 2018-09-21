# Bug Fixes

- Fixed improper configuration of Syslog draining that prevented external
  drains from working. Syslog drains bound to app should work again.
- Fixed Locket and Diego using wrong database name regardless of configuration

# Important, Please Read

Previously, we had an incorrect spruce operation that confused `scheme` and
`schema`, which resulted in locketdb and diegodb data being written to a
database named `postgres` (rather than `locketdb` and `diegodb`, respectively.)

If you are upgrading from CF Genesis Kit version 1.1.0, 1.1.1, or 1.1.2, a
Genesis Migration Process (GMP) must be performed. Please review
[GMP-CF-0001: Database Scheme Fix Migration][gmp-cf-0001]

[gmp-cf-0001]: http://www.genesisproject.io/docs/migrations/gmp-cf-0001


# Versions

## Core Components

| Release | Version | Release Date |
| --------- | ------- | ------------ |
bpm (new) | [0.6.0](https://github.com/cloudfoundry-incubator/bpm-release/releases/tag/v0.6.0) | 2 May 2018
capi | [1.60.0](https://github.com/cloudfoundry/capi-release/releases/tag/1.60.0) | 15 Jun 2018
cf-smoke-tests | 40.0.5 | 17 May 2018
cf-networking (new) | [1.9.0](https://github.com/cloudfoundry/cf-networking-release/releases/tag/v1.9.0) | 15 Dec 2017
cflinuxfs2 | [1.212.0](https://github.com/cloudfoundry/cflinuxfs2-release/releases/tag/v1.212.0) | 4 Jun 2018
cf-routing | [0.178.0](https://github.com/cloudfoundry/routing-release/releases/tag/0.178.0) | 17 May 2018
cf-syslog-drain (new) | [7.0](https://github.com/cloudfoundry/cf-syslog-drain-release/releases/tag/v7.0) | 6 Jul 2018
consul | [193](https://github.com/cloudfoundry-incubator/consul-release/releases/tag/v193) | 29 May 2018
diego | [2.8.0](https://github.com/cloudfoundry/diego-release/releases/tag/v2.8.0) | 28 May 2018
garden-runc | [1.14.0](https://github.com/cloudfoundry/garden-runc-release/releases/tag/v1.14.0) | 4 Jun 2018
loggregator | [102.2](https://github.com/cloudfoundry/loggregator-release/releases/tag/v102.2) | 25 May 2018
nats | [24](https://github.com/cloudfoundry/nats-release/releases/tag/v24) | 16 May 2018 
postgres | [3.1.3](https://github.com/cloudfoundry-community/postgres-boshrelease/releases/tag/v3.1.3) | 6 Sep 2018
statsd-injector | [1.3.0](https://github.com/cloudfoundry/statsd-injector-release/releases/tag/v1.3.0) | 23 Mar 2018
uaa | [59](https://github.com/cloudfoundry/uaa-release/releases/tag/v59) | 22 May 2018


## Buildpacks

| Buildpack | Version | Release Date |
| --------- | ------- | ------------ |
binary | [1.0.19](https://github.com/cloudfoundry/binary-buildpack/releases/tag/v1.0.19) | 5 Jun 2018
dotnet-core | [2.0.7](https://github.com/cloudfoundry/dotnet-core-buildpack/releases/tag/v2.0.7) | 5 Jun 2018
go | [1.8.23](https://github.com/cloudfoundry/go-buildpack/releases/tag/v1.8.23) | 5 Jun 2018
java | [4.12](https://github.com/cloudfoundry/java-buildpack/releases/tag/v4.12) | 11 May 2018
nodejs | [1.6.25](https://github.com/cloudfoundry/nodejs-buildpack/releases/tag/v1.6.25) | 5 Jun 2018
php | [4.3.56](https://github.com/cloudfoundry/php-buildpack/releases/tag/v4.3.56) | 5 Jun 2018
python | [1.6.17](https://github.com/cloudfoundry/python-buildpack/releases/tag/v1.6.17) | 5 Jun 2018
ruby | [1.7.19](https://github.com/cloudfoundry/ruby-buildpack/releases/tag/v1.7.19) | 5 Jun 2018
staticfile | [1.4.28](https://github.com/cloudfoundry/staticfile-buildpack/releases/tag/v1.4.28) | 5 Jun 2018