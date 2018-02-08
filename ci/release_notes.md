# Improvements

- Add new `session_timeout` param, which can be set to the number of days before
  the refresh token for BOSH CLI login sessions expires. Defaults to one day.
- The Azure CPI has been updated to version 35.0.0

# Bug Fixes

- Resource pools, networks, and disk pools are now pruned from the base
  manifest, instead of just being nil'd.  This prevents some instances where
  the cloud config was being ignored.
