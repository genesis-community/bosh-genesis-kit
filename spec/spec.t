#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;

# kit-validator's lib is either on PERL5LIB (kit-CI convention) or
# supplied via the KIT_VALIDATOR_LIB env var (local iteration).
BEGIN { require lib; lib->import($ENV{KIT_VALIDATOR_LIB}) if $ENV{KIT_VALIDATOR_LIB} }

use Genesis::Kit::Validator::Spec qw/kit_dir test_env/;
use Test::More;

kit_dir("$FindBin::Bin/..");

# --- addons -----------------------------------------------------------------
test_env(name => 'external-db',           cloud_config => 'vsphere');
test_env(name => 'external-db-no-tls',    cloud_config => 'vsphere');
test_env(name => 'skip-op-users',         cloud_config => 'vsphere');
test_env(name => 'vault-credhub-proxy',   cloud_config => 'vsphere');
test_env(name => 'node-exporter',         cloud_config => 'vsphere');
test_env(name => 'blacksmith-integration',cloud_config => 'vsphere');
test_env(name => 'openbao',               cloud_config => 'vsphere');

# OpenBao seal modes.  The openbao env above sets no seal mode and has no
# exodus data, so it is a new env and takes the static default.  The seal
# keys in these fixtures are fake (repeated 0a and 0b bytes).
test_env(name => 'openbao-static',          cloud_config => 'vsphere');
test_env(name => 'openbao-shamir',          cloud_config => 'vsphere');
test_env(name => 'openbao-static-rotation', cloud_config => 'vsphere');

# An env that has deployed OpenBao before (exodus has_openbao) and sets no
# seal mode renders the Shamir seal it already runs, and the check stops
# the deploy until the operator chooses a mode.
test_env(
	name         => 'openbao-existing',
	cloud_config => 'vsphere',
	exodus       => 'openbao-existing',
	output_matchers => {
		genesis_check    => qr/deployed OpenBao before.*openbao_seal: shamir/s,
		genesis_manifest => qr/seal:\s+type: shamir/s,
	},
);

# OpenBao does not trim the key file, so a stored key with a trailing
# newline would stop the server; the check fails without printing it.
test_env(
	name         => 'openbao-static-key-newline',
	cloud_config => 'vsphere',
	output_matchers => {
		genesis_check    => qr/surrounding whitespace \(65 characters stored\)/,
		genesis_manifest => qr/current_key:/,
	},
);

# Anything other than static or shamir stops the blueprint.
test_env(
	name         => 'openbao-seal-invalid',
	cloud_config => 'vsphere',
	output_matchers => {
		genesis_check    => qr/openbao_seal.*must be.*static.*shamir.*auto/s,
		genesis_manifest => qr/openbao_seal.*must be.*static.*shamir.*auto/s,
	},
);

# bbr: the dedicated SSH account lands in the user_add job that
# op-users.yml rewrites, so cover it both with that file in the merge and
# with skip-op-users, where the kit has to supply the os-conf release
# itself.
test_env(name => 'bbr',                   cloud_config => 'vsphere');
test_env(name => 'bbr-skip-op-users',     cloud_config => 'vsphere');
# NOTE: no ocfp+openbao spec env - the ocfp feature needs bloc config in
# vault (secret/config/<bloc>/...) and create-env, which the validator
# sandbox does not provide (no ocfp env has ever been spec-tested).  The
# combination is covered by the lab e2e instead.

# openbao and vault-credhub-proxy both bind :8200 on the director; the
# blueprint rejects the combination at the default port.
test_env(
	name   => 'openbao-proxy-conflict',
	cloud_config => 'vsphere',
	output_matchers => {
		# The blueprint bails during fragment determination, so both the
		# check and manifest steps surface the conflict message.
		genesis_check    => qr/openbao.*vault-credhub-proxy|vault-credhub-proxy.*openbao/is,
		genesis_manifest => qr/openbao.*vault-credhub-proxy|vault-credhub-proxy.*openbao/is,
	},
);

test_env(name => 'all-addons',            cloud_config => 'vsphere');
test_env(name => 'all-addons-source',     cloud_config => 'aws');

# --- cpis --------------------------------------------------------------------
# aws
test_env(name => 'proto-aws');
test_env(name => 'proto-all-params-aws');
test_env(name => 'aws',                                            cloud_config => 'aws');
test_env(name => 'aws-iam-profile-s3-blobstore-iam-profile',       cloud_config => 'aws');
test_env(name => 'aws-iam-profile-s3-blobstore',                   cloud_config => 'aws');
test_env(name => 'aws-iam-profile',                                cloud_config => 'aws');
test_env(name => 'aws-s3-blobstore-iam-profile',                   cloud_config => 'aws');
test_env(name => 'aws-s3-blobstore',                               cloud_config => 'aws');
test_env(name => 'proto-aws-iam-profile');
test_env(name => 'proto-aws-iam-profile-s3-blobstore-iam-profile');
test_env(name => 'proto-aws-iam-profile-s3-blobstore');
test_env(name => 'proto-aws-s3-blobstore-iam-profile');
test_env(name => 'proto-aws-s3-blobstore');

# azure
test_env(name => 'proto-azure');
test_env(name => 'proto-all-params-azure');
test_env(name => 'azure',                 cloud_config => 'azure');

# google
test_env(name => 'proto-google');
test_env(name => 'proto-all-params-google');
test_env(name => 'google',                cloud_config => 'google');

# openstack
test_env(name => 'proto-openstack');
test_env(name => 'openstack',             cloud_config => 'openstack');

# pve
test_env(name => 'proto-pve');
test_env(name => 'pve',                   cloud_config => 'pve');

# PVE opt-in feature regression: pve-userpass-auth is valid-listed but only
# takes effect on the ocfp path (ocfp/pve/auth-userpass.yml), so the plain
# path must treat it as a no-op instead of bailing "feature is invalid"
# (same defect class d399612 fixed for pve-ha-dlb).
test_env(name => 'pve-userpass-auth',     cloud_config => 'pve');

# pve parker prefix and the pve-storage-sets feature, on a create-env env so
# both the director's own CPI job block and the cloud_provider block are in
# the golden. parker_prefix has to appear in both; the storage-set properties
# must appear in neither, because overlay/cpis/pve-storage-sets.yml only loads
# on the ocfp path and deliberately has no proto counterpart (the CPI cannot
# lock an allocation journal on the machine that runs create-env).
#
# That is also why this golden cannot show what the feature renders when it IS
# active, including the director.cpi_additional_volumes mount that gives the
# BPM workers sight of the journal directory. No ocfp env can be spec-tested at
# all (see the NOTE above), so spec/unit/pve-storage-sets.t asserts the whole
# rendered property set instead, mount included.
test_env(name => 'proto-pve-parker-storage-sets');

# pve multi-AZ CPI plumbing (P2-T1): bosh-configs.director-cpi.{cpis,default,
# az_map} schema-acceptance regression -- proves the new env-file keys pass
# through env-file processing without altering the rendered director
# manifest.  The per-AZ cpi-selection logic itself (the kit's
# cpi_name_for_az override plus the base-class AZ-definition loop) is
# covered by spec/unit/cloud-config-director-az-map.t,
# not reachable here -- see that file's header comment for why.
# The per-AZ cpi entries reference director-credhub paths for their API
# tokens; the validator has no credhub, so supply them as literals via the
# credhub_variables fixture or bosh int's --var-errs pass fails.
test_env(
	name         => 'pve-multi-az',
	cloud_config => 'pve',
	credhub_vars => 'pve-multi-az',
);

# vsphere
test_env(name => 'proto-vsphere');
test_env(name => 'proto-all-params-vsphere');
test_env(name => 'vsphere',               cloud_config => 'vsphere');
test_env(name => 'vsphere-s3-blobstore',  cloud_config => 'vsphere');

test_env(name => 'warden-vsphere',        cloud_config => 'vsphere');

test_env(
	name         => 'ops-override',
	cloud_config => 'vsphere',
	ops          => [qw/test-ops-override/],
);

# --- catch-all top-level -----------------------------------------------------
test_env(name => 'all-params');
test_env(name => 'proto-all-params-source-vsphere');

# --- upgrade path ------------------------------------------------------------
test_env(name => 'upgrade', exodus => 'old-version');

# too-old-to-upgrade: the env expects genesis to reject at every step.
# Testkit's OutputMatchers regex is translated here as the matching
# case-insensitive multi-line Perl regex.
test_env(
	name   => 'too-old-to-upgrade',
	exodus => 'too-old-version',
	output_matchers => {
		genesis_add_secrets => qr/please\s+upgrade\s+to\s+at\s+least\s+bosh\s+kit\s+2.3.0\s+before\s+upgrading/is,
		genesis_check       => qr/please\s+upgrade\s+to\s+at\s+least\s+bosh\s+kit\s+2.3.0\s+before\s+upgrading/is,
		genesis_manifest    => qr/please\s+upgrade\s+to\s+at\s+least\s+bosh\s+kit\s+2.3.0\s+before\s+upgrading/is,
	},
);

done_testing;
