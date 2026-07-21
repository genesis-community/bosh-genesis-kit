# Colocated OpenBao Operations Runbook

This runbook covers day-1 and day-2 operations for the OpenBao server
colocated on a BOSH director via this kit's `openbao` feature.

Throughout, `<env>` is the Genesis environment name, and the OpenBao endpoint
is `https://<params.static_ip>:<params.openbao_port or 8200>`.

## Architecture Recap

- Single OpenBao node on the director VM, managed by monit wrapping bpm.

- Storage: integrated Raft on the director's persistent disk at
  `/var/vcap/store/openbao/raft`.

- TLS: kit-issued certificates from the deploying vault at
  `secret/<env-path>/bosh/openbao/{ca,server}`; the server certificate has
  `params.static_ip` as a SAN.

- Seal: Shamir, 5 key shares, threshold 3. There is no auto-unseal by
  default — a restart leaves the server sealed until an operator unseals it.

## Secret Custody Model

Three copies of the unseal keys exist after initialization:

- The operator capture from `openbao-init` output (printed exactly once)

- The deploying vault, at `<secrets_base>/openbao/seal/keys` (and the root
  token at `<secrets_base>/openbao/root_token`)

- In-cluster at `secret/vault/seal/keys` (the `safe` auto-unseal convention
  path — note this copy cannot unseal the cluster it lives in)

Nothing is ever written to the director VM filesystem: no unseal keys, no
root token.

### Capture Rules

When running `openbao-init` (or any command that prints key material):

- Run under `umask 077`

- If you must log the session, use `script(1)` writing to a `0600` file in
  your home directory

- Never capture in a tmux pane (scrollback is readable by anything with the
  socket), and never write key material under `/tmp`

- Distribute the five key shares to separate custodians; no single custodian
  should hold three or more

## Initialization (Day 1)

Run once, after the first successful deploy:

```shell
umask 077
genesis <env> do openbao-init
```

What it does:

1. Verifies the OpenBao listener is reachable

2. Prints the capture-rules warning, targets the server via `safe`, and runs
   `safe init` — which unseals the new server, authenticates with the root
   token, and stores the keys in-cluster at `secret/vault/seal/keys`

3. Verifies the in-cluster key copy exists

4. Backs the keys and root token up to the deploying vault under
   `<secrets_base>/openbao/`

5. Prints the full init output once for operator capture

Side effect: your active `safe` target is left switched to the new OpenBao
(target name `<env>`). This is deliberate — `ocfp vault migrate` uses the
current target as its destination — but switch back explicitly if you need
the previous vault.

## Health Check Codes

`curl -sk https://<ip>:<port>/v1/sys/health` returns:

| Code | Meaning | Action |
|------|---------|--------|
| 200 | Initialized, unsealed, active | None |
| 429 | Unsealed, standby | None (single node: unexpected) |
| 473 | Performance standby | None |
| 501 | Not initialized | `openbao-init` |
| 503 | Sealed | `openbao-unseal` |

`genesis <env> do openbao-status` reports the same via `safe status`.

## Unseal (After Restart or Recreate)

OpenBao seals whenever the process restarts, the VM reboots, or the VM is
recreated. To unseal:

```shell
genesis <env> do openbao-unseal
```

This uses the seal-key backup in the deploying vault automatically; if that
is unavailable it prompts for keys interactively (3 custodians required).

## Seal (Incident Response)

If you suspect compromise of the server or a token:

```shell
genesis <env> do openbao-seal
```

Sealing discards the in-memory master key. Everything served by this OpenBao
becomes unavailable until quorum unseals it again.

## Targeting and Authentication

```shell
genesis <env> do openbao-target [METHOD]
```

Creates the `safe` target `<env>` and authenticates (default method:
`token`). Day-to-day access should use non-root tokens or another auth
method; see root-token rotation below.

## Root Token Rotation

The initial root token should be treated as a bootstrap credential:

1. Set up a durable auth method and admin policy (e.g. userpass, cert, or
   OIDC) using the root token

2. Revoke the initial root token: `bao token revoke <token>` (or
   `safe -T <env> vault token revoke -self`)

3. Delete the stored copy from the deploying vault:
   `safe rm <secrets_base>/openbao/root_token`

If a root token is later needed, generate one with quorum:
`bao operator generate-root` (requires 3 key shares), and revoke it when
done.

## Rekey (Rotating the Unseal Keys)

If a custodian leaves or a share is exposed:

```shell
bao operator rekey -init -key-shares=5 -key-threshold=3
# then, three times, each custodian:
bao operator rekey
```

After a successful rekey, update both backup copies (deploying vault and
in-cluster path) and re-run custody distribution. The old shares are dead.

## Backup and Restore

Raft snapshots are the unit of backup:

```shell
# backup (authenticated)
bao operator raft snapshot save openbao-<env>-$(date +%Y%m%d).snap

# restore (to a fresh, initialized node)
bao operator raft snapshot restore openbao-<env>-<date>.snap
```

Complement snapshots with a logical export of critical paths via
`safe export secret >export.json` (encrypt at rest, same custody rules as
keys). Snapshot before every director redeploy that touches the persistent
disk.

## VM Lifecycle Behavior

| Event | Raft data | Seal state | Action |
|-------|-----------|------------|--------|
| Process restart (monit) | Kept | Sealed | `openbao-unseal` |
| `bosh recreate` (director-deployed) | Kept (persistent disk survives) | Sealed | `openbao-unseal` |
| `create-env` update (no VM change) | Kept | Unsealed | None |
| `create-env` `--recreate` | Kept | Sealed | `openbao-unseal` (kit pins a stable node_id) |
| `create-env` `--recreate`, deployed before release 0.3.1 | Kept, but raft cannot elect | Sealed | Unseal, then peers.json recovery (below) |
| Persistent disk loss | **Lost** | n/a | Restore from snapshot onto a re-initialized node, or total loss |

## Raft Recovery After create-env Recreate

The kit pins `openbao.raft.node_id` to `<env>-openbao` (release 0.3.1+),
so VM recreation does not disturb the raft identity and this section does
not apply to new deployments. It remains for deployments made with release
0.3.0, whose raft data was created under the release default — the BOSH
instance id (`spec.id`). There, a director-deployed `bosh recreate`
preserves the instance id, so the node rejoins its own raft cleanly, but a
`create-env` VM recreate assigns a NEW instance id: the persisted raft
configuration still lists only the old node id as voter, so after
unsealing, the node stays a permanent standby — reads work, writes fail
with `local node not active but active cluster node not found`, and
`sys/leader` shows no leader. The same one-time recovery applies when
upgrading an existing 0.3.0 deployment to the pinned node_id.

Recover with a peers.json election override:

1. Get the new node id:
   `grep node_id /var/vcap/jobs/openbao/config/openbao.hcl`

2. `monit stop openbao`, then write
   `/var/vcap/store/openbao/raft/raft/peers.json` (note: inside the `raft/`
   subdirectory, owned by `vcap:vcap`):

   ```json
   [{"id":"<new-node-id>","address":"<static-ip>:8201","non_voter":false}]
   ```

3. `monit start openbao`, then unseal (3 keys). The node consumes
   peers.json, elects itself, and becomes active with all data intact.

## Self-Hosted Provider: create-env Recreate Sequence

When this OpenBao is the bloc's secrets provider and its own director is
updated by `create-env`, Genesis renders the manifest while the provider is
still up, recreates the VM, and then cannot write exodus data — the
provider comes back sealed. Genesis prints `Exodus data update may fail
due to sealed vault` and then blocks on an interactive vault-auth prompt
in non-interactive runs: kill it, unseal (plus raft recovery above if the
VM was recreated), and rerun `genesis deploy` — the deploy itself already
succeeded; the rerun is a no-op that completes the exodus write.

## Break-Glass: Provider Down During create-env

A management director update takes its colocated OpenBao down for the
duration — and Genesis needs a secrets provider to render the manifest. If
this OpenBao *is* the bloc's provider:

1. On the bastion, start a temporary local vault: `safe local --memory`
   (or restore the latest `safe export` into it)

2. Import the env's secrets: `safe import <export.json`

3. Point `.genesis/config` (`secrets_provider`) at the temporary vault,
   deploy the director, then repoint at the OpenBao endpoint

4. Unseal the updated OpenBao (`openbao-unseal`) and verify with
   `openbao-status`; discard the temporary vault

Plan management-director updates as provider outages: quiesce bloc deploys
first.

## Port Conflict with vault-credhub-proxy

`openbao` and `vault-credhub-proxy` both bind port 8200 on the director
address. The blueprint refuses the combination; to run both, set
`params.openbao_port` to a free port and redeploy.
