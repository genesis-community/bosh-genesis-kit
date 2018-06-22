# New Features

- A new `runtime-config` addon script has been added to generate a
  BOSH runtime config for adding two users to all deployed BOSH
  VMs:  **netop** has an SSH key (generated and stored in the Vault)
  and can be used for out-of-band SSH management; **sysop** has a
  type-able password for use in things like the vCenter remote
  console.  Operators can choose to deploy both, one, or neither.

- Proto-BOSH deployments will have the netop / sysop users added
  by default, unless you activate the `skip_op_users` feature
  flag.

- Operators can now inject custom X.509 certificate authorities
  into deployed VMs via the `trusted_certs` parameter.  Now you
  too can [run your own Certificate Authority!][1]

# Improvements

- The `login` and `logout` addon scripts now always set up the
  BOSH env alias, even if you already have one.  This helps in lab
  situations, where the CA cert may change often across regular
  secret rotation and/or slash-and-burn redeployment.

- The kit now checks your NATS certificates for mTLS, to ensure
  that they are valid and usable in modern gnatsd implementations.
  This is particularly useful to people upgrading from the 0.1.x
  versions of this kit, which generated certs that are
  incompatible with the 0.2.x series.

[1]: https://jameshunt.us/writings/roll-your-own-x509-ca.html
