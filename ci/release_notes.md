**NOTE:** as this release brings some drastic re-numbering of core
component IP addressing schemes, you may want to validate that
your environment configuration stays reachable through an update.

# Improvements

- The `access` instance group, which used to terminate `cf ssh`
  traffic and proxy it to the proper backend Diego LRP, has been
  rolled into the existing `router` instance group.

  This means that `router` is now the sole ingress point for
  traffic entering the Cloud Foundry runtime.

  The former `ssh-elb` and `cf-elb` BOSH VM extensions have been
  replaced with a the new `cf-load-balanced` extension.  You will
  need to update your cloud-config accordingly.

  **NOTE:** during the upgrade to this version of the CF Kit, BOSH
  will delete the now-unused `access` VMs, cutting off any `cf
  ssh` traffic until the first `router` instance finishes booting
  up.  Traffic to CF applications should be available throughout.

- The (now-EOL'd) `cflinuxfs2` stack is now optional, and will not
  be deployed by default.  If you still need to provide the rootfs
  and the accompanying buildpacks, use the new `cflinuxfs2`
  feature.

- (Almost) All Static IPs are GONE!  The `router` instance group
  now uses dynamically-assigned IPs exclusively, and communicates
  to Cloud provider loadbalancers (ALBs, ELBs, etc.) via BOSH
  VM Extensions.  The `nats` instance group continues to use its
  link, and no longer requires staticly-assigne IPs.  Same with
  `doppler` instances.

- VM type defaults have been renamed to reflect the instance group
  that they pertain to.  For example, the `api` instance group now
  defaults to `api`, not `medium`.  See **VM Type Changes**,
  below, for the full story.


# Bug Fixes

- Unused `autoscaler-pruner` references have been removed.

# VM Type Changes

This release introduces new defaults for VM types, to make it
easier to size different roles properly.  Here is the full set of
changes:

| Instance Group | Old Default | New Default | Recommendation  |
|----------------| ----------- | ----------- | --------------- |
| api            | medium      | api         | 2 cpu /  4g mem |
| bbs            | small       | bbs         | 1 cpu /  2g mem |
| cell           | runtime     | cell        | 4 cpu / 15g mem |
| diego          | medium      | diego       | 2 cpu /  4g mem |
| doppler        | small       | doppler     | 1 cpu /  2g mem |
| smoke-tests    | small       | errand      | 1 cpu /  2g mem |
| loggregator    | medium      | loggregator | 2 cpu /  4g mem |
| nats           | small       | nats        | 1 cpu /  2g mem |
| router         | small       | router      | 1 cpu /  2g mem |
| syslogger      | small       | syslogger   | 1 cpu /  2g mem |
| uaa            | medium      | uaa         | 2 cpu /  4g mem |

# Core Components

**NOTE:** this release provides no material software or stemcell updates over the previous release.

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

**NOTE:** this release provides no material software or stemcell updates over the previous release.

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
