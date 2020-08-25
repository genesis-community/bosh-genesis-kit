# Upgrade Documentation
In your deployment repo, run the following command to download the kit you want to
upgrade to.

```
genesis fetch-kit bosh/version
```

Go to the environment file you want to upgrade, modify the kit version accordingly
in the following section.

```
---
kit:
  name: bosh
  version: new_version
```

You may need modify/add/remove params for kit version upgrade depending on the changes in the kits.


## Upgrading from v1.15.2 to v2.x
Before we deploy we need to do the following
check before the upgrade if you are on the latest 1x version (1.15.2)
### add missing secrets
`add-secrets 'MANIFEST'`
### rotate problematic certificates
`rotate-secrets --problematic 'MANIFEST'`
#### NOTE!
> If your nats cert is problematic, it will cause a new nats cert to be generated, which will result in all deployed instances by this BOSH director to be recreated.  This can cause downtime, so best to not rotate these certs until you're sure this wont happen or will happen at a non-critical time.


### Known problems upgrading
there are some edge cases which may fail the upgrade.
- upgrading from an older release than 1.15.x may result in unable to stop hm component 
