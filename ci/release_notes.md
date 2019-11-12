# New Features

- Container to container networking and service discovery (via an
  internal Cloud Foundry domain) is now supported by the new
  `dns-service-discovery` feature.  This new feature subsumes and
  replaces the `app-bosh-dns` feature, which only implemented half
  of the solution for direct communication between CF application
  containers.

# Improvements

- This Kit now provisions some new (empty) UAA groups, that users
  can be added to for various permissions inside of CF:

    1. `network.read`
    2. `cloud_controller.read_only_admin`
    3. `cloud_controller.global_auditor`

- The admin account in UAA now has the `network.admin` scope,
  allowing it to see network policies created by anyone.
