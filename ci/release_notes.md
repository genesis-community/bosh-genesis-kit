# Improvements

* Improved External Database Support:

  * Added ability to specify a MySQL external database (fixes #88)

  * The `external-db` feature is deprecated in favor of explicitly using
    `external-db-postgres` or `external-db-mysql`.  If encountered, postgres
    is assumed.

  * The standalone `external-db-ca` is now the incorporated into the default
    unless `external-db-no-tls` is used, as you can't have TLS without it.
    (fixes #89)

  * Fix registry feature when using external-db-\* feature

  * Make params for db name and username for external db (fixes #87)

  * The various user passwords found on external DB have been moved to
    user-provided instead of generated, and is supported by a common derived
    feature named '+external-db'

* Added External S3 Blobstore Support

  Provides the `s3-blobstore` feature, which has uses
  `params.s3_blobstore_region` and `params.s3_blobstore_bucket` to identify
  the target, and `blobstore/s3:access_key` and `blobstore/s3:secret_key`
  secrets for authorization.

* Added IAM Instance Profile for VM creation and S3 blobstores, instead of
  using AWS access and secret keys.

  Adds `iam-instance-profile` and `s3-blobstore-iam-instance-profile`
  features.  `s3-blobstore` feature still has to be specified if you want to
  use the s3 blobstore. (fixes #85 and #86)

# Bug Fixes

* Fix openstack secrets paths and legacy feature name support

* Provide support (with Genesis v2.7.8) for multiline CGP credentials secret
  rotation and addition.

* Minor output fixes for addon hook

* Improved manifest generation (blueprint hook) messages

* Refactored to support derived features

  The addition of iam-instance-profiles and s3 buckets required derived
  features to validate secrets that need to be present when those new
  features AREN'T present.

  Further refactored the blueprint hook to facilitate better condition
  checking and merge orders.

* Added specs for testing feature scenarios including iam instance profiles,
  external db, and s3 buckets.

* Update manual with params.availability_zones

* Added `testkit` specs for testing feature scenarios across various IaaS
  and environment configurations.


