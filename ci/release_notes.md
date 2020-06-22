# Improvements

* Added a `blacksmith-integration` feature:

  * Allows the blacksmith genesis
  kit to seamlessly use a director deployed by the bosh genesis kit to deploy
  services.
  * This will add a `blacksmith` user that
  only has permissions to interact with its own deployments, upload releases,
  and upload stemcells