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

- Seal: either `static` or `shamir`, chosen by `params.openbao_seal`. A static seal unseals the server automatically from a key that the kit keeps in the deploying vault, and the init keys become five recovery keys with a threshold of three. A Shamir seal has five key shares with a threshold of three, and a restart leaves the server sealed until an operator unseals it. New environments start with `static`. See Static Seal Mode below.

## Secret Custody Model

This section describes a Shamir seal. A static seal keeps different material in different places, and its custody table is under Static Seal Mode below.

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

In static mode, `openbao-init` doesn't use `safe init`. It sends the init request to `sys/init` with five recovery shares and a threshold of three, passing the request body and the root token to curl on stdin so that neither appears on a command line. It stores the recovery keys at `<secrets_base>/openbao/seal/keys` with `kind: recovery` beside them, and the root token at `<secrets_base>/openbao/root_token`. It then mounts `secret/` as KV v2 and writes `secret/handshake`, just as `safe init` would. It prints the recovery keys and the root token once, under the same capture rules. There is no in-cluster copy at `secret/vault/seal/keys` in static mode, because recovery keys can't unseal anything, and the static path doesn't change our `safe` target.

Before either kind of initialization, `openbao-init` checks whether `<secrets_base>/openbao/seal/keys` or `<secrets_base>/openbao/root_token` already holds something. That happens when a server is rebuilt with an empty disk, and the old keys may be the only way to restore one of its raft snapshots. The addon copies each path that exists to the same path with a UTC timestamp suffix, such as `openbao/seal/keys-20261006T141500Z`, reads the copy back, and compares the two by SHA-256. It initializes only when every copy matches, and it prints the path names but never the contents.

Side effect: your active `safe` target is left switched to the new OpenBao
(target name `<env>`). This is deliberate — `ocfp vault migrate` uses the
current target as its destination — but switch back explicitly if you need
the previous vault.

## Health Check Codes

`curl -sk https://<ip>:<port>/v1/sys/health` returns:

| Code | Meaning | Action |
|------|---------|--------|
| 200 | Initialized, unsealed, active | None |
| 429 | Unsealed, standby | Fault on this single-node topology: writes fail. See Raft Recovery below |
| 473 | Performance standby | Fault on this single-node topology: writes fail. See Raft Recovery below |
| 501 | Not initialized | `openbao-init` |
| 503 | Sealed | Shamir: `openbao-unseal`. Static: a fault, or a seal migration in progress. See Static Seal Mode below |

`genesis <env> do openbao-status` reports the same via `safe status`. Before that, it reads `sys/seal-status` and reports the seal type, the mode the environment expects, whether a migration is pending, and whether the server is sealed. It flags a sealed static server as a fault and a type that differs from the expected mode as a mismatch.

After every deploy, the post-deploy step `openbao-seal-type` compares the seal type the server reports with `params.openbao_seal`, and the deploy report fails the step when they differ. It skips the comparison while a seal migration is pending, because the server reports its old type until the migration completes.

## Unseal (After Restart or Recreate)

OpenBao seals whenever the process restarts, the VM reboots, or the VM is
recreated. To unseal:

```shell
genesis <env> do openbao-unseal
```

This uses the seal-key backup in the deploying vault automatically; if that
is unavailable it prompts for keys interactively (3 custodians required).

A static server unseals itself when the process starts, so `openbao-unseal` checks `sys/seal-status` first. If the server is already unsealed, the addon has nothing to do. If a seal migration is pending, it explains the migration and sends no keys. If a static server is sealed, it says so, because that is a fault. The usual causes are a missing or wrong key file, or an operator who sealed the server by hand. The first thing to try is `monit restart openbao` on the director, then read the openbao log, where a key file with stray whitespace shows up as `unknown encoding for AES-256 key`. Only for a server that was sealed by hand does the addon offer to unseal with the stored recovery keys, and it asks for confirmation before it sends any.

## Seal (Incident Response)

If you suspect compromise of the server or a token:

```shell
genesis <env> do openbao-seal
```

Sealing discards the in-memory master key. Everything served by this OpenBao
becomes unavailable until quorum unseals it again.

With a static seal, sealing doesn't last. The key file is still on the director, so the next job restart or reboot unseals the server again without anyone's help. To keep a static server sealed during an incident, stop the job with `monit stop openbao` on the director after sealing it, and leave it stopped until the incident is over. If the director itself may be compromised, treat the static key as exposed too, and plan to rotate it.

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

With a static seal, the five keys are recovery keys, and we rotate them with `bao operator rekey -target=recovery` in the same way. Afterwards, we update `<secrets_base>/openbao/seal/keys` and the escrow copy, and we keep `kind: recovery` in both. The static seal key itself is rotated with the `openbao-rotate-seal-key` addon, described under Static Seal Mode.

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

The table describes a Shamir seal. With a static seal, every event that keeps the raft data and the key file comes back unsealed with no action. A server that stays sealed after one of them is a fault, and Static Seal Mode below covers what to check.

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
VM was recreated), and rerun `genesis deploy` with the state file this
deploy wrote, as described below. The deploy itself already succeeded.

Genesis saves the create-env state into exodus only after the exodus write
succeeds, so the state that knows about the new VM is never saved. A plain
rerun retrieves the older state from exodus, deletes the VM it names, and
tries to create a second director, which the CPI refuses with an IP
conflict. Before rerunning, copy
`.genesis/deploy-cache/<env>/<env>-state.json` into a `0700` directory and
rerun with `genesis deploy <env> --STATE-FILE-PATH <copy>`. If that file is
already gone, rebuild it from the newest successful deployment in exodus:
extract `artifacts[0]` from `<exodus>/deployments/<timestamp>`, set
`current_vm_cid` in its state file to the running director's VM cid, and
pass that file instead. Delete the extracted artifacts afterwards, because
they include the full manifest and its credentials.

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

With a static seal, the updated OpenBao unseals itself when it starts, so the unseal in step 4 isn't needed. We still verify it with `openbao-status` before discarding the temporary vault.

## Static Seal Mode

A static seal lets OpenBao unseal itself from a 32-byte key, so a restart, a reboot, or a recreate no longer needs three custodians. The price is that the key sits on the same VM as the data it protects. Anyone with root on the director, with access to its storage, or with a backup of the VM holds both the ciphertext and the key. We accept that trade for each environment on purpose, and we keep an escrow copy of the key, because losing the key loses everything that OpenBao stores.

Static mode needs openbao-boshrelease 0.4.0 or later, which is the release the kit pins. An environment that overrides the openbao release under `releases:` has to point at 0.4.0 or later before it chooses static. If the server keeps running a Shamir seal after a deploy in static mode, the post-deploy `openbao-seal-type` step reports the mismatch.

### Choosing the Mode

The mode comes from `params.openbao_seal`, which is either `static` or `shamir`. Any other value fails the deploy. Environments that don't use the `openbao` feature ignore the parameter entirely.

- New environments
  When the parameter is missing, the kit defaults to `static` only for an environment it can prove is new. That means the deploying vault answered, and the environment's exodus path doesn't exist in it. The kit never contacts OpenBao to decide. `genesis new` doesn't write the parameter for this kit, so we add `openbao_seal: static` to the environment file ourselves, which makes the choice visible to the next reader and spares every command a vault lookup.

- Existing environments
  An environment that has exodus data but no recorded mode, or one the kit can't prove is new because the vault was unreachable or the lookup was ambiguous, renders a Shamir seal. Its `genesis check` and `genesis deploy` fail until we set the parameter. Setting `openbao_seal: shamir` keeps the server exactly as it is. Setting `openbao_seal: static` starts the migration described below. The kit never moves an existing server to a static seal on its own.

- The exodus record
  Every deploy records the mode it rendered as `openbao_seal` in the exodus data. When the parameter is missing, the kit keeps the recorded mode and warns that the mode should be written into the environment file.

A second parameter, `openbao_seal_static_disabled`, is used only when going back to Shamir. Setting it to `true` while `openbao_seal` is `static` keeps the static seal stanza but marks it disabled, which is how OpenBao starts a static-to-Shamir migration. With `openbao_seal: shamir`, the check hook refuses the flag.

### Key Custody

The deploying vault holds the following paths, all under `<secrets_base>`:

| Path | Keys | What it holds |
|------|------|---------------|
| `openbao/seal/static` | `key` | The current static seal key, as 64 lowercase hex characters. `genesis add-secrets` generates it once, and it is marked `fixed`, so `rotate-secrets` never replaces it. |
| `openbao/seal/static-previous` | `key`, `id` | The outgoing key and its key id, present only while a rotation is under way. The id is `sha256-` followed by the first 16 hex characters of the SHA-256 of the decoded key bytes. |
| `openbao/seal/keys` | `key1` to `key5`, `kind` | The five keys from `openbao-init`. In static mode they are recovery keys, and `kind: recovery` says so. |
| `openbao/root_token` | `token` | The initial root token, until it is revoked and deleted. |
| `openbao/seal/escrow` | `target`, `url`, `cluster_id`, `id`, `previous_id`, `escrowed_at` | The record of the last verified escrow. It holds no secret. It records the escrow vault's target name, URL, and cluster id (when the vault reports one), along with the ids of the keys that vault holds. Only the rotation addon writes it, and only after every copy matched by SHA-256. |

The escrow vault holds a copy of `openbao/seal/static` and, during a rotation, of `openbao/seal/static-previous`. It must be a different vault from the deploying vault, and in a bloc it is usually the inception vault on the bastion. The addon compares vaults rather than target names, so it refuses an escrow target whose URL matches the deploying vault's after normalizing case, the trailing slash, and the default port. It also refuses one whose `sys/health` reports the same `cluster_id` as the deploying vault. It checks every escrow copy by comparing SHA-256 sums of the two exports, and it never prints either one.

The exodus data carries two key ids, which are not secret. After every deploy that leaves a static server unsealed, the post-deploy step records `openbao_static_key_id`, the id of the key the server is now running on. During a rotation, the previous-key overlay also renders `openbao_static_previous_key_id`. Before each deploy, the check hook derives the id of the key in the deploying vault and compares it with the recorded one. If they differ, the vault's key was most likely generated fresh by a secrets fix or restored from the wrong escrow copy, and the check stops the deploy rather than replace the key file the server needs. When nothing is recorded yet, which is the case before the first static deploy and during a migration, the check instead requires the escrow record to name the current key's id.

The recovery keys can't decrypt anything. They authorize `bao operator generate-root`, rotation of the recovery keys, unsealing after a manual seal, and a migration back to Shamir. We keep them under the same custody rules as Shamir shares.

On the director, the release renders the key to `/var/vcap/jobs/openbao/config/seal/current.key`, and during a rotation it also renders the previous key to `seal/previous.key` beside it. We can check that file's owner and mode with `stat` when we need to, but we never read its contents.

### Handling the Key by Hand

OpenBao 2.7.1 doesn't trim whitespace from a key file. A hex key with a trailing newline fails startup with `unknown encoding for AES-256 key`, and the server stays sealed. The kit's check hook reads the stored value raw and fails the deploy when it has surrounding whitespace, without printing it.

Whenever we write or copy a key by hand, we use `printf %s`, and never `echo`, because `echo` adds a newline. For example, if a key file on the director has to be put back by hand, the value goes in with `printf %s "$KEY" > <file>` from a variable that was itself read without a newline, and the file keeps the owner and mode the release gave it. The same rule applies to any `safe set` of a key, which should take the value from a file or a pipe built with `printf %s`.

To check a stored key's shape without showing it, run `genesis <env> check`, which reports whether the key is empty, has surrounding whitespace, is the wrong length, or isn't lowercase hex. A pipe such as `safe get <path>:key | tr -d '\n' | grep -Eq '^[0-9a-f]{64}$'` confirms the characters, but it can't tell us whether the stored value ends in a newline, because `tr` removes it first.

### Seal Type Checks

`openbao-status` and the post-deploy `openbao-seal-type` step both compare the type in `sys/seal-status` with the environment's mode. The post-deploy step accepts a pending migration only when `params.openbao_seal` is set in the environment file. A migration that starts while the mode came from the new-environment default or the exodus record is an accident, so the step fails and explains how to back it out. A static environment whose server reports `shamir` usually means the release is older than 0.4.0, or a migration hasn't been finished. A sealed static server is always a fault, so start with `monit restart openbao` on the director and the openbao log, not with recovery keys.

### Migrating From Shamir to Static

A migration moves an existing, initialized Shamir server to a static seal. It keeps all of the data, and the five Shamir shares become recovery keys. Plan it as a provider outage, because the server is sealed from the deploy until the shares are submitted. If anything else depends on this OpenBao, such as Concourse credentials, pause it first.

Before the change, we take these read-only steps, none of which prints a secret:

1. Record the seal status with `curl -s --cacert <openbao-ca> https://<ip>:<port>/v1/sys/seal-status | jq '{type,sealed,t,n,version}'`. We expect `shamir`, unsealed, a threshold of 3 of 5, and the running version.

2. Confirm that `sys/leader` reports `is_self`, and record the number of secrets by piping `safe paths` to `wc -l`.

3. Confirm that the vault holding the shares has all five at `<secrets_base>/openbao/seal/keys` by listing the key names with `safe get --keys`. If this OpenBao is the bloc's secrets provider, the shares have to come from the escrow vault, because the provider is sealed during the migration.

4. Take a raft snapshot with `bao operator raft snapshot save`, with the root token exported into the environment and never placed on the command line. Store it in a `0700` directory under your home on the bastion, never under `/tmp`. This snapshot can only be restored with the Shamir shares.

Then the migration itself goes like this:

1. Move the environment to release 0.4.0 or later and set `params.openbao_seal: static` in the environment file.

2. Run `genesis add-secrets <env>`, which generates `openbao/seal/static`. Then run `genesis <env> check` to confirm the key's shape without printing it.

3. Escrow the key with `genesis <env> do openbao-rotate-seal-key escrow --escrow-target <escrow>`. The addon copies the key to the escrow vault in memory, compares the two copies by SHA-256, and only then writes the escrow record at `openbao/seal/escrow`. Run `genesis <env> check` again, which now reports the key id with the escrow verified. The check fails any deploy that starts the static seal without that record, so this step can't be skipped.

4. Run `genesis deploy <env>`. The openbao job restarts with the static stanza, and OpenBao comes up sealed with a migration pending. If this OpenBao is the bloc's provider, the exodus write then stalls on the sealed provider, as described under Self-Hosted Provider above. Stop it, because the deploy itself has already succeeded. Then copy `.genesis/deploy-cache/<env>/<env>-state.json` into a `0700` directory, because it's the only record of the new VM until exodus is written (see Self-Hosted Provider above).

5. Confirm that `sys/seal-status` shows `migration: true` and `sealed: true`.

6. Submit three shares with `migrate` set. Each share goes straight from the vault into the request, so that it never reaches the command line, a file, or the screen:

   ```bash
   for i in 1 2 3; do
     safe -T <escrow> get <secrets_base>/openbao/seal/keys:key$i \
       | jq -Rc '{key: ., migrate: true}' \
       | curl -sS --cacert "$CA" -X PUT --data @- https://<ip>:<port>/v1/sys/unseal \
       | jq '{sealed, progress, migration}'
   done
   ```

7. Run `genesis deploy <env>` again. For a self-hosted provider, pass `--STATE-FILE-PATH` with the state file you copied in step 4, because a plain rerun starts from the pre-migration state in exodus and tries to create a second director. The rerun completes the exodus write. Its post-deploy step sees the static server unsealed and records `openbao_static_key_id`, which every later check compares with the key in the vault.

8. Mark the shares as recovery keys by running `safe set <secrets_base>/openbao/seal/keys kind=recovery` against the deploying vault and the escrow vault.

The migration counts as complete only when every one of these checks passes:

- The openbao log on the director shows `seal migration initiated` and then `seal migration complete`.

- `sys/seal-status` reports type `static`, `recovery_seal: true`, `sealed: false`, `migration: false`, and a threshold of 3 of 5.

- `sys/health` returns 200, `sys/leader` reports `is_self`, `secret/handshake` exists, and the number of secrets matches the count we took before the change.

- After `monit restart openbao` on the director, the server is unsealed again within seconds, with no help.

### Going Back to Shamir

How we go back depends on where the migration stopped:

- A pending migration
  If no threshold of `migrate` shares was reached, storage hasn't changed. Finishing the migration is the simplest way out. To back out instead, remove the seal stanza from the rendered `/var/vcap/jobs/openbao/config/openbao.hcl` on the director by hand, restart the job, unseal with the Shamir shares as usual, and then deploy with `openbao_seal: shamir`. The edit on the VM comes first because Genesis can't render anything while the provider is sealed.

- A completed migration
  Set `params.openbao_seal_static_disabled: true` and deploy. OpenBao comes up sealed with a static-to-Shamir migration pending. Submit three recovery keys with `migrate` set, using the same pipe as above, and they become Shamir unseal keys again. Then set `openbao_seal: shamir`, remove the disabled flag, deploy again to drop the stanza, and unseal once with `openbao-unseal`. Keep the static key in escrow until all of this is done. Finally, remove the `kind` key with `safe rm <secrets_base>/openbao/seal/keys:kind` in both vaults, because the five keys are unseal keys again.

- The last resort
  Restore the raft snapshot taken before the change onto a node running a Shamir seal, and unseal it with the original shares.

### Rotating the Static Key

The `openbao-rotate-seal-key` addon rotates the static key from n-1 to n. It refuses to run unless the environment is in static mode and the server is unsealed, static, and not migrating. It never prints a key, and no key reaches a command line.

1. Start the rotation, naming the escrow vault:

   ```shell
   genesis <env> do openbao-rotate-seal-key start --escrow-target <escrow>
   ```

   The addon stores the current key and its id at `openbao/seal/static-previous`, escrows that path, generates a new key at `openbao/seal/static` with `safe gen`, and escrows the new key. It checks each escrow copy by SHA-256, and then it writes the escrow record with the new key's id. If a run stops part way through, running `start` again picks up where it left off. Passing `--skip-escrow` instead of `--escrow-target` rotates without an escrow copy, but we then have to run the `escrow` action before we deploy, because `finish` refuses until the new key has a verified escrow.

2. Deploy with `genesis deploy <env>`. The manifest now carries both keys, and on the unseal that follows, OpenBao decrypts with the previous key and re-wraps its keys under the new one.

3. On the director, check the openbao log for a line that says `post-unseal upgrade seal keys failed`. If one appears, stop here, because the previous key has to stay in place.

4. Restart the job once with `monit restart openbao`, and confirm with `genesis <env> do openbao-status` that it comes back unsealed on the new key.

5. Finish the rotation:

   ```shell
   genesis <env> do openbao-rotate-seal-key finish
   ```

   Before it asks anything, the addon runs four checks. The escrow record must name the new key's id. The exodus data must record the previous key's id, which shows that a deploy rendered both keys. The exodus data must also record the new key's id, which shows that the server came up unsealed on it after that deploy. And the server must be static and unsealed right now. Any failed check stops it. It then asks us to confirm the three conditions above, and `--yes` answers that question when there's no terminal, but it never skips a check. Only then does it remove `openbao/seal/static-previous` from the deploying vault. `finish` doesn't accept `--skip-escrow`.

6. Deploy again to drop the previous key from the configuration, and restart the job once more. Only after that restart comes back unsealed do we remove `openbao/seal/static-previous` from the escrow vault.

Two more actions help with repairs. The `escrow` action copies both keys to the escrow vault again and rewrites the escrow record, and the `repair-id` action rewrites the id stored beside the previous key when `genesis <env> check` reports that it's missing or wrong.

## Port Conflict with vault-credhub-proxy

`openbao` and `vault-credhub-proxy` both bind port 8200 on the director
address. The blueprint refuses the combination; to run both, set
`params.openbao_port` to a free port and redeploy.
