# Improvements

The BOSH Genesis Kit now leverages some exciting new features in
Genesis v2.5.0+, notably blueprints and feature flags.  Existing
environments should be able to update to this version without any
undue stress of churn, but a few "refreshes" are desirable.

- The `*-init` subkits are gone, and have been replaced by
  combining two feature flags, `proto` and `$iaas` (i.e.
  `vsphere`, `aws`, etc.)

- The `credhub` subkit is gone; CredHub is now included implicitly
  in all deployments of the BOSH director.

- The `proxy` subkit is now gone.  If you specify proxy
  parameters, they will be honored.  If you don't they default to
  "no proxy in effect".
