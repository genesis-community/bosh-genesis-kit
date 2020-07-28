# Improvements

- Allow credhub cli to connect via client/secret auth as well as
  username/password.

  The `credhub-login` addon will continue to use the username/password method,
  creating a local token.  However, when other kits need to access the bosh's
  credhub for their own secrets management needs, they will provide
  `CREDHUB_*` environment variables and connect via client/secrets method.

  This functionality change is available in and required by Genesis v2.7.11.
  Please upgrade to Genesis v2.7.11, then deploy this version of the bosh kit
  prior to deploying any further kits.
