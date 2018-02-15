# Bug Fixes

- Top-level manifest keys that `bosh create-env` needs for the
  proto-BOSH / bosh-init subkit are now properly pruned only for
  so-called "normal" BOSH deployments, not everything.  This fixes
  our ability to deploy proto-BOSHes.

  Our CI pipeline has been retrofitted with a new test that
  exercises the bosh-init + vsphere configuration, to catch future
  regressions that follow in the same vein.
