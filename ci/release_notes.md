# Bug Fixes

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

