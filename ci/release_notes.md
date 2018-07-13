## Bug Fixes
* CRITICAL: A distributed Minio manifest would only deploy 1 Minio instance.
* Fixed a typo in the post-deploy

## New Features
* `s3` addon command, which will automatically set your envvars and run commands
  against `s3`.

## Changes
* The default port for Minio is now `443` instead of `9000`