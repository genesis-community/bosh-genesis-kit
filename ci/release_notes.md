# Improvements

- Added `minio-blobstore` feature -- see MANUAL.md for details

# Bug Fixes

- Fix `bosh-dns-healthcheck` feature - thanks @michaelmccaskill (#126)

- Better support for `params.dns` when specifying a single entry - thanks
  @michaelmccaskill (#122)

- Recent changes in the bosh-cli broke the login addon.  Empty environment variables is treated as a value.

- Fixes for rutime addon:

  1. Use overlay style for including os-conf release because it gets concated
     into an existing overlay style file, which was incompatible with its
     previous operator style.

  2. Improve runtime-config interface, to give better feedback for runtime
     uploads.

  3. Delete genesis.ops-access runtime if both netop-access and sysop-access
     features are not present (instead of uploading an empty runtime config)

  4. Fix exclude of genesis-local-users runtime job (it was in the wrong
     level, and therefore uneffective.

