# BOSH Genesis Kit Upgrade Guide

This document provides instructions for upgrading your BOSH Genesis Kit deployments between versions.

## General Upgrade Instructions

In your deployment repository, run the following command to download the kit you want to upgrade to:

```bash
genesis fetch-kit bosh/version
```

> **Note:** The legacy command `genesis download bosh/version` still works but is deprecated.

Go to the environment file you want to upgrade, and modify the kit version:

```yaml
---
kit:
  name: bosh
  version: new_version
  # features remain unchanged
```

You may need to modify, add, or remove params for kit version upgrades depending on the changes in the kits.

## Upgrading to v3.x

### From v2.x

Upgrading from v2.x to v3.x is generally straightforward. Follow these steps:

1. Fetch the latest kit version:
   ```bash
   genesis fetch-kit bosh/3.0.5
   ```

2. Update your environment file to use the new version:
   ```yaml
   kit:
     name: bosh
     version: 3.0.5
   ```

3. Check for any missing secrets:
   ```bash
   genesis add-secrets <env-name>
   ```

4. Deploy the updated environment:
   ```bash
   genesis deploy <env-name>
   ```

### From v1.x to v3.x

When upgrading from v1.x directly to v3.x, we recommend first upgrading to the latest v2.x release, and then to v3.x.

## Upgrading from v1.x to v2.x

Before deploying, perform the following steps:

1. Ensure you are on the latest v1.x version (1.15.2):
   ```bash
   genesis fetch-kit bosh/1.15.2
   ```

2. Update your environment file to use v1.15.2, then deploy.

3. Add any missing secrets:
   ```bash
   genesis add-secrets <env-name>
   ```

4. Rotate problematic certificates:
   ```bash
   genesis rotate-secrets --problematic <env-name>
   ```

   > **Warning:** If your NATS cert is problematic, rotation will cause a new NATS cert to be generated. This will result in all VMs deployed by this BOSH director being recreated, which can cause downtime. Plan this rotation for a maintenance window if possible.

5. Fetch and deploy the v2.x kit:
   ```bash
   genesis fetch-kit bosh/2.0.0
   genesis deploy <env-name>
   ```

### Known problems upgrading

- Upgrading from an older release than 1.15.x may result in being unable to stop the health monitor component.
- Some addons have changed between v1.x and v2.x, check the documentation for the latest command usage.