# Improvements

- Stemcells are now pinned to 3468.latest, instead of latest,
  since that is the major version that our compiled BOSH releases
  are compiled against.

- When deploying to vSphere, `genesis new` now asks for what
  resource pool you want to deploy to, underneath the cluster,
  and generates the appropriate environment YAML structures.

# Bug Fixes

- Fix bad default value for `params.trusted_certs` (should have
  been an empty string instead of nil.  Now it's an empty string,
  and all is right with the world).

- The `aws_key_name` being erroneously emitted by `genesis new`
  for the AWS IaaS/cloud is no more, leading to less confusion
  when deploying to Amazon EC2.
