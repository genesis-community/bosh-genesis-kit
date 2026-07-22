#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;

# kit-validator's lib is either on PERL5LIB (kit-CI convention) or
# supplied via the KIT_VALIDATOR_LIB env var (local iteration).
BEGIN { require lib; lib->import($ENV{KIT_VALIDATOR_LIB}) if $ENV{KIT_VALIDATOR_LIB} }

use Genesis::Kit::Validator qw/kit_dir test_env/;
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

# pve multi-AZ CPI plumbing (P2-T1): bosh-configs.director-cpi.{cpis,default,
# az_map} schema-acceptance regression -- proves the new env-file keys pass
# through env-file processing without altering the rendered director
# manifest.  The per-AZ cpi-selection logic itself (build_az_definitions /
# _cpi_name_for_az) is covered by spec/unit/cloud-config-director-az-map.t,
# not reachable here -- see that file's header comment for why.
test_env(name => 'pve-multi-az',          cloud_config => 'pve');

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
