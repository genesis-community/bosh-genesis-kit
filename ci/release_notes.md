# Major Update

This release brings the releases used by the CF Genesis Kit up to date with
[v9.5.0 of the cf-deployment release][cfd-9.5.0].  This release is
upgradable from the previous releases (assuming you go through the removal
of `consul` as per releases v1.3.x - v1.5.x of this kit).

[cfd-9.5.0]: https://github.com/cloudfoundry/cf-deployment/releases/tag/v9.5.0

# Improvements

- Space Developers are now able to set up network policies without platform
  operator involvement.

- Containerd is now the default containerization runtime for Diego, instead
  of garden/runc.  If you want the old behavior, you can specify the
  `native-garden-runc` feature.

- You can now set the VM update strategy via the `vm_strategy` param.

- gorouter and access VMs now provide shared BOSH links.

- App Autoscaler has been fixed and upgraded to 2.0.0, thanks to
  [anishp55][pr54].

- NFS Volume Services has been upgraded to v2.3.0 (see below for details).

- Consul has been officially removed (see below for details).

- Significant improvements to move communications to TLS

- Additional loggregator metrics

[pr54]: https://github.com/genesis-community/cf-genesis-kit/pull/54


## NFS Volume Services

NFS Volume Services, which can be enabled via the `nfs-volume-services` feature,
has been upgraded to v2.3.0.  This should be paired with the [updated
nfs-broker genesis kit][nfsbroker-0.2.0]

[nfsbroker-0.2.0]: https://github.com/genesis-community/nfs-broker-genesis-kit/releases/tag/v0.2.0

## Regarding Consul Deprecation

Consul is no longer supported, and was removed in release v1.5.0.  While
replacing consul with BOSH DNS was optional since v1.3.0 using the feature
`migrate-1.3-without-consul`, that feature is no longer necessary..

You should be able to directly upgrade to this version with no impact to your
existing Cloud Foundry system.  We recommend that you validate by upgrading
to v1.4.1 with `migrate-1.3.1-without-consul` enabled so that if something
does break, you can redeploy without that feature.

You must [enable BOSH DNS](https://bosh.io/docs/dns/#enable) in your BOSH
deployment via runtime config
[(example)](https://github.com/cloudfoundry/bosh-deployment/blob/master/runtime-configs/dns.yml)
to deploy this version.


# Core Components

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| app-autoscaler | [2.0.0](https://github.com/cloudfoundry-incubator/app-autoscaler-release/releases/tag/v2.0.0) | 15 August 2019 |
| bosh-dns-aliases | [0.0.3](https://github.com/cloudfoundry/bosh-dns-aliases-release/releases/tag/v0.0.3) | 24 October 2018 |
| bpm | [1.1.0](https://github.com/cloudfoundry/bpm-release/releases/tag/v1.1.0) | 28 May 2019 |
| capi | [1.83.0](https://github.com/cloudfoundry/capi-release/releases/tag/1.83.0) | 28 June 2019 |
| cf-cli | [1.16.0](https://github.com/bosh-packages/cf-cli-release/releases/tag/v1.16.0) | 04 June 2019 |
| cf-networking | [2.23.0](https://github.com/cloudfoundry/cf-networking-release/releases/tag/2.23.0) | 17 June 2019 |
| cf-smoke-tests | [40.0.112](https://github.com/cloudfoundry/cf-smoke-tests-release/releases/tag/v40.0.112) | - |
| cf-syslog-drain | [10.2](https://github.com/cloudfoundry/cf-syslog-drain-release/releases/tag/v10.2) | 13 May 2019 |
| cflinuxfs2 | [1.286.0](https://github.com/cloudfoundry/cflinuxfs2-release/releases/tag/v1.286.0) | 12 June 2019 |
| cflinuxfs3 | [0.113.0](https://github.com/cloudfoundry/cflinuxfs3-release/releases/tag/v0.113.0) | 08 July 2019 |
| diego | [2.34.0](https://github.com/cloudfoundry/diego-release/releases/tag/v2.34.0) | 02 July 2019 |
| garden-runc | [1.19.3](https://github.com/cloudfoundry/garden-runc-release/releases/tag/v1.19.3) | 25 June 2019 |
| haproxy | [9.7.1](https://github.com/cloudfoundry-incubator/haproxy-boshrelease/releases/tag/v9.7.1) | 05 September 2019 |
| log-cache | [2.2.2](https://github.com/cloudfoundry/log-cache-release/releases/tag/v2.2.2) | 31 May 2019 |
| loggregator | [105.5](https://github.com/cloudfoundry/loggregator-release/releases/tag/v105.5) | 06 May 2019 |
| loggregator-agent | [3.9](https://github.com/cloudfoundry/loggregator-agent-release/releases/tag/v3.9) | 15 March 2019 |
| mapfs | [1.2.0](https://github.com/cloudfoundry/mapfs-release/releases/tag/v1.2.0) | 15 July 2019 |
| nats | [27](https://github.com/cloudfoundry/nats-release/releases/tag/v27) | 16 May 2019 |
| nfs-volume | [2.3.0](https://github.com/cloudfoundry/nfs-volume-release/releases/tag/v2.3.0) | 21 August 2019 |
| postgres | [3.2.0](https://github.com/cloudfoundry-community/postgres-boshrelease/releases/tag/v3.2.0) | 19 September 2019 |
| routing | [0.188.0](https://github.com/cloudfoundry-incubator/cf-routing-release/releases/tag/0.188.0) | 12 April 2019 |
| silk | [2.23.0](https://github.com/cloudfoundry/silk-release/releases/tag/2.23.0) | 17 June 2019 |
| statsd-injector | [1.10.0](https://github.com/cloudfoundry/statsd-injector-release/releases/tag/v1.10.0) | 16 April 2019 |
| uaa | [72.0](https://github.com/cloudfoundry/uaa-release/releases/tag/v72.0) | 14 May 2019 |


# Buildpacks

| Release | Version | Release Date |
| ------- | ------- | ------------ |
| binary | [1.0.32](https://github.com/cloudfoundry/binary-buildpack-release/releases/tag/1.0.32) | 01 May 2019 |
| dotnet-core | [2.2.12](https://github.com/cloudfoundry/dotnet-core-buildpack-release/releases/tag/2.2.12) | 14 June 2019 |
| go | [1.8.39](https://github.com/cloudfoundry/go-buildpack-release/releases/tag/1.8.39) | 01 May 2019 |
| java | [4.19](https://github.com/cloudfoundry/java-buildpack-release/releases/tag/4.19) | 26 April 2019 |
| nginx | [1.0.13](https://github.com/cloudfoundry/nginx-buildpack-release/releases/tag/1.0.13) | 14 June 2019 |
| nodejs | [1.6.51](https://github.com/cloudfoundry/nodejs-buildpack-release/releases/tag/1.6.51) | 14 June 2019 |
| php | [4.3.77](https://github.com/cloudfoundry/php-buildpack-release/releases/tag/4.3.77) | 14 June 2019 |
| python | [1.6.34](https://github.com/cloudfoundry/python-buildpack-release/releases/tag/1.6.34) | 14 June 2019 |
| r | [1.0.10](https://github.com/cloudfoundry/r-buildpack-release/releases/tag/1.0.10) | 14 June 2019 |
| ruby | [1.7.40](https://github.com/cloudfoundry/ruby-buildpack-release/releases/tag/1.7.40) | 14 June 2019 |
| staticfile | [1.4.43](https://github.com/cloudfoundry/staticfile-buildpack-release/releases/tag/1.4.43) | 14 June 2019 |

