# Homeserver Infra Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage the homeserver and its Cloudflare resources from one repository, with encrypted secrets, off-site backup and tested restore.

**Architecture:** `apps.yaml` is the single app list, read by both OpenTofu (Cloudflare) and Ansible (server). Everything is applied from the MacBook through `make`; secrets are injected as environment variables by `sops exec-env`. Ansible is proven on a throwaway VM before it touches the real server.

**Tech Stack:** OpenTofu (Cloudflare provider v5, R2 S3 backend), Ansible (`community.docker`, `community.general`), Docker Compose, restic, SOPS + age, GitHub Actions, Renovate, Multipass.

**Spec:** `docs/superpowers/specs/2026-11-27-homeserver-infra-design.md`

## Global Constraints

- Repository root: `/Users/anvu-neli/homeserver-infra`. Code, identifiers and commit messages in English.
- Never commit, push or open a PR unless the owner says so. Each task ends at a checkpoint: report and wait.
- No plaintext secret in git or on the MacBook disk. Tasks needing secret values have the owner type them into `sops`; never into chat.
- Server: `kiman@100.99.61.56`, LAN `192.168.31.110/24`, Ubuntu 26.04. App directory stays `~/apps/<name>`.
- Published ports bind to `${BIND_IP}` (the Tailscale IP), never `0.0.0.0`.
- Images pinned to an exact version tag; `latest` is forbidden.
- `access` is `private` or `public`; default `private`.
- Backup daily at 03:00; keep 7 daily, 4 weekly, 6 monthly. Heartbeat every 5 minutes.
- Zone `kimanlab.online`. Access login: Google only.
- Comments only for non-obvious reasons.

## Review Focus

1. Typo in `apps.yaml` (`acces: public`, `access: Public`): rejected, nothing becomes public. Task 3.
2. Missing or empty secret: stops before any server change, no empty `.env` written. Task 4.
3. Exposed app whose compose file is not on network `tunnel`: validation fails naming the app. Task 2.
4. Backup fails or is interrupted: stopped containers start again and the failure URL is pinged. Task 6.
5. Restore against an empty or unreachable repository: fails clearly, live data untouched, backup timer stays off. Task 6.

## File Structure

```
apps.yaml                      app list
apps/{beszel,cloudflared,dozzle}/compose.yaml
tofu/{versions,variables,apps,tunnel,access,dns,backup,outputs}.tf
tofu/tests/exposure.tftest.hcl
ansible/{ansible.cfg,requirements.yml,site.yml,restore.yml}
ansible/inventory/{prod,test}.yml
ansible/roles/{base,docker,firewall,apps,backup,heartbeat,thermal}/
scripts/validate_apps.py       schema check for apps.yaml and compose files
scripts/vm.sh                  create and destroy the test VM
tests/test_validate_apps.py
tests/test_backup.sh
tests/vm.env                   dummy values, no real secrets
secrets/prod.sops.yaml
.sops.yaml  Makefile  .gitignore  .yamllint  renovate.json
.github/workflows/check.yml
```

---

### Task 1: Repository, tools and secrets

**Files:** Create `.gitignore`, `.sops.yaml`, `Makefile`, `secrets/prod.sops.yaml`.

**Interfaces — Produces:** these exact environment variable names, used by every later task:
`CLOUDFLARE_API_TOKEN`, `TF_VAR_account_id`, `TF_VAR_state_passphrase`, `TF_VAR_access_allowed_emails` (comma separated), `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3`, `BACKUP_R2_ACCESS_KEY_ID`, `BACKUP_R2_SECRET_ACCESS_KEY`, `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `BESZEL_TOKEN`, `BESZEL_KEY`, `DOZZLE_PASSWORD_HASH`, `HEALTHCHECKS_HEARTBEAT_URL`, `HEALTHCHECKS_BACKUP_URL`.
Make variable `SOPS_RUN = sops exec-env secrets/prod.sops.yaml`.

- [ ] **Step 1:** Ask the owner to approve, then run `brew install ansible ansible-lint restic yamllint gitleaks` and `brew install --cask multipass`. Verify each with `--version`.
- [ ] **Step 2:** `git init -b main`. `.gitignore` covers `*.env` (except `tests/vm.env`), `*.tfstate*`, `*.tfplan`, `.terraform/`, `keys.txt`.
- [ ] **Step 3:** Generate the age key at `~/.config/sops/age/keys.txt` (do not overwrite an existing one); put its public key in `.sops.yaml` for `secrets/.*\.sops\.yaml$`. Owner confirms the private key is saved in a password manager.
- [ ] **Step 4:** Owner creates R2 bucket `homeserver-tfstate`, its scoped R2 key, the API token and two Healthchecks checks. Token permissions: Account: Cloudflare Tunnel Edit, Access Apps and Policies Edit, Workers R2 Storage Edit; Zone `kimanlab.online`: DNS Edit, Zone Read.
- [ ] **Step 5:** Owner fills `secrets/prod.sops.yaml` with `sops`. Backup R2 keys stay empty until Task 3.
- [ ] **Step 6:** Verify: `grep -c 'ENC\[' secrets/prod.sops.yaml` is at least 16 and `gitleaks dir .` reports no leaks.
- [ ] **Step 7:** Checkpoint.

### Task 2: App definitions and validator

**Files:** Create `apps.yaml`, the three `apps/*/compose.yaml`, `scripts/validate_apps.py`, `tests/test_validate_apps.py`, `tests/vm.env`.

**Interfaces — Produces:**
`apps.yaml` entry: `name` (required), `data` (list of directories relative to the app directory, default `[]`), `env` (list of variable names, default `[]`), `expose` (optional: `hostname`, `service`, `access`).
`validate(root: Path) -> list[str]` returns error messages; CLI exits 1 when non-empty.
Compose variable `BIND_IP`.

Entries: `beszel` (data `beszel_data`, `beszel_agent_data`; env `BESZEL_TOKEN`, `BESZEL_KEY`; expose `beszel.kimanlab.online`, `beszel:8090`, `private`), `cloudflared` (env `TUNNEL_TOKEN`), `dozzle` (data `data`; port 8080 on `BIND_IP`).

- [ ] **Step 1: Failing tests** (each builds a temp tree):

```python
def test_valid_repository_has_no_errors(): assert validate(REPO_ROOT) == []
def test_unknown_key_is_rejected(tmp_path):      # expose.acces: public
    assert "acces" in " ".join(validate(tree(tmp_path, expose={"acces": "public"})))
def test_access_value_is_case_sensitive(tmp_path):
    assert validate(tree(tmp_path, expose={"access": "Public"}))
def test_exposed_app_must_join_tunnel_network(tmp_path):
    assert "blog" in validate(tree(tmp_path, name="blog", networks=[]))[0]
def test_port_without_bind_ip_is_rejected(tmp_path):
    assert validate(tree(tmp_path, ports=["8080:8080"]))
def test_latest_tag_is_rejected(tmp_path):
    assert validate(tree(tmp_path, image="traefik/whoami:latest"))
def test_duplicate_hostname_is_rejected(tmp_path): assert validate(two_apps_same_hostname(tmp_path))
```

- [ ] **Step 2:** `python3 -m pytest tests -q` fails on import.
- [ ] **Step 3:** Implement the validator. Read the running versions on the server (`docker exec beszel /beszel --version`, `docker exec cloudflared cloudflared --version`) and pin those; pin Dozzle to its current release from the official repository. Start from the compose files on the server; replace the literal IP with `${BIND_IP}`, set Beszel `APP_URL` to `https://beszel.kimanlab.online`, keep agent `HUB_URL` on `${BIND_IP}:8090`, join `beszel` to external network `tunnel`, enable Dozzle simple auth with `data/users.yml`.
- [ ] **Step 4:** Tests pass; `docker compose --env-file tests/vm.env config -q` passes for each app (run on the VM or CI if Docker is absent on the Mac).
- [ ] **Step 5:** Checkpoint.

### Task 3: Cloudflare with OpenTofu

**Files:** Create `tofu/*.tf`, `tofu/tests/exposure.tftest.hcl`. Modify `Makefile`.

**Interfaces — Consumes:** `apps.yaml`, Task 1 variables. **Produces:** sensitive output `tunnel_token`; bucket `homeserver-backup`; targets `make plan`, `make tofu-apply`. Variable `apps_file` (default `../apps.yaml`).

- [ ] **Step 1: Failing tests** with `mock_provider "cloudflare"` and fixture app files under `tofu/tests/fixtures/`:
  - `no_expose_creates_no_dns_or_access`: both resource maps are empty.
  - `access_defaults_to_private`: an expose without `access` yields one Access application.
  - `public_has_dns_without_access`: one DNS record, zero Access applications.
  - `unknown_access_value_fails`: `expect_failures` for `access: Public`.
  - `unknown_expose_key_fails`: `expect_failures` for `acces: public`.
  - `ingress_ends_with_404`: last ingress rule service is `http_status:404`.
- [ ] **Step 2:** `tofu -chdir=tofu test` fails.
- [ ] **Step 3:** Implement. Confirm resource schemas with `tofu providers schema -json` first. Resources: `cloudflare_zero_trust_tunnel_cloudflared` (name `homeserver-iac`), its `_config`, `cloudflare_dns_record` (proxied CNAME to `<tunnel id>.cfargotunnel.com`), `cloudflare_zero_trust_access_application` and `_policy`, `cloudflare_r2_bucket`. Config and DNS `depends_on` Access. S3 backend with `use_lockfile`; `encryption` block using `pbkdf2` and `aes_gcm`, enforced for state and plan.
- [ ] **Step 4:** Tests, `tofu fmt -check`, `tofu validate` pass.
- [ ] **Step 5:** Run `make plan`; show it to the owner. Apply only on approval. Before DNS exists nothing on the server changes.
- [ ] **Step 6:** Verify: `curl -sI https://beszel.kimanlab.online` redirects to `cloudflareaccess.com`; second `make plan` shows no changes.
- [ ] **Step 7:** Owner creates an R2 key scoped to `homeserver-backup` and adds it with `sops`. Checkpoint.

### Task 4: Ansible base, docker, apps on a test VM

**Files:** Create `ansible/` config, inventories, `site.yml`, roles `base`, `docker`, `apps`, `thermal`, `heartbeat`, `scripts/vm.sh`. Modify `Makefile`.

**Interfaces — Consumes:** `apps.yaml`, env names. **Produces:** inventory variables `bind_ip`, `lan_cidr`, `vpn_interface`, `apps_skip` (test: `[cloudflared]`), `apps_dir`; targets `make vm-up`, `make vm-test`, `make vm-down`, `make check`, `make deploy` (reads `tofu output -raw tunnel_token` into env `TUNNEL_TOKEN`, never to disk).

- [ ] **Step 1: Failing check:** `make vm-test` runs the playbook twice and fails unless the second recap has `changed=0`; then asserts over SSH that containers `beszel`, `dozzle` are running and nothing listens on `0.0.0.0:8090`.
- [ ] **Step 2: Failing check:** with `BESZEL_KEY` unset, the play fails in `pre_tasks` naming the variable, and `~/apps` is not created. Same for an empty string.
- [ ] **Step 3:** Implement roles per the spec table. `apps` renders `.env` mode `0600` with `no_log`, creates network `tunnel`, runs the validator on localhost first. Port `/usr/local/bin/thermal-log` and its units from the server byte for byte; it must not fail on a VM lacking those sensors, so enable its timer only when `coretemp` and `dell_smm` exist. Pin the Docker packages' major version.
- [ ] **Step 4:** Both checks pass; `ansible-lint` and `yamllint .` clean.
- [ ] **Step 5:** Checkpoint.

### Task 5: Firewall role

**Files:** Create `ansible/roles/firewall/`. Modify `site.yml`.

**Interfaces — Consumes:** `lan_cidr`, `vpn_interface`. **Produces:** tag `firewall`, skipped unless `-e firewall_confirmed=true`.

- [ ] **Step 1: Failing check** in `vm-test`: `ufw status verbose` shows default deny incoming, allow on `vpn_interface`, port 22 from `lan_cidr`; no pending `ufw-rollback` timer.
- [ ] **Step 2:** Implement: rules first, then `systemd-run --on-active=5min --unit=ufw-rollback ufw disable`, enable, `reset_connection`, `wait_for_connection`, stop the rollback timer.
- [ ] **Step 3:** On the VM, set a wrong `lan_cidr` and empty `vpn_interface` rule, confirm the rollback disables `ufw` after the timeout, then restore settings.
- [ ] **Step 4:** Check passes twice with `changed=0`. Checkpoint.

### Task 6: Backup and restore

**Files:** Create `ansible/roles/backup/`, `ansible/restore.yml`, `tests/test_backup.sh`. Modify `Makefile`.

**Interfaces — Consumes:** `data` from `apps.yaml`, restic and Healthchecks variables. **Produces:** `/usr/local/bin/homeserver-backup`, `homeserver-backup.timer`, marker `/var/lib/homeserver/backup-enabled`; `make backup`, `make restore [APPLY=1] [SNAPSHOT=<id>]`, `make backup-init`.

- [ ] **Step 1: Failing tests** (VM, local restic repository):
  - `restore_to_temp_matches_source`: checksums equal.
  - `failed_backup_restarts_containers`: wrong password; containers running afterwards, `<url>/fail` requested on a local stub.
  - `killed_backup_restarts_containers`: SIGTERM mid-run; containers running.
  - `restore_from_empty_repo_fails_safely`: non-zero exit, live checksums unchanged, timer disabled.
  - `restore_apply_requires_confirmation`: answering anything but `yes` changes nothing.
  - `fresh_machine_restores_before_apps_start`: destroy VM, deploy with `restore_first=true`, data matches.
- [ ] **Step 2:** `make vm-test` fails.
- [ ] **Step 3:** Implement. Stop only apps with non-empty `data`; restart through a `trap`. Include `/var/log/thermal.csv` if present. The timer is enabled only when the marker exists; `make backup-init` or a successful applied restore creates it.
- [ ] **Step 4:** All pass. Checkpoint.

### Task 7: CI and Renovate

**Files:** Create `.github/workflows/check.yml`, `.yamllint`, `renovate.json`.

- [ ] **Step 1:** Workflow on `pull_request`, `permissions: contents: read`, no secrets, actions pinned by commit SHA: pytest, validator, `tofu fmt -check`, `init -backend=false`, `validate`, `test`, `ansible-lint`, `yamllint`, `docker compose config -q` with `tests/vm.env`, `gitleaks`.
- [ ] **Step 2:** Renovate covers compose images, providers, actions; automerge off.
- [ ] **Step 3:** Run the same commands locally; all pass.
- [ ] **Step 4:** Checkpoint. When the owner says "tạo pull", create the private repository, push, open the PR and confirm CI is green.

### Task 8: Cut over the real server

Run remotely over Tailscale; the owner accepts that a lost connection waits until someone reaches the laptop. Each step needs approval.

- [ ] **Step 1:** Record listening ports, containers, volumes. Confirm, read-only: `docker.sources` is the only Docker apt source; only `docker-ce` packages; `daemon.json` hash equals the repository copy; compose projects `beszel`/`cloudflared` with bind mounts under `~/apps`; no named volumes. Anything different or not in the spec: stop and ask. Do not pass `restore_first=true` on this server.
- [ ] **Step 2:** Stop Beszel, archive `~/apps` to `~/apps-pre-iac.tar.gz` (mode `0600`), start it.
- [ ] **Step 3:** `make check` (shows file changes only; it does not preview container recreation), review the diff, then `make deploy` without firewall. Verify old Beszel history is present and `beszel.kimanlab.online` asks for Access first.
- [ ] **Step 4:** Create Dozzle login; verify it opens only on the Tailscale IP.
- [ ] **Step 5:** `make backup-init`, `make backup`, `make restore`; compare restored files.
- [ ] **Step 6:** Deploy with `firewall_confirmed=true`. Verify a new SSH session over Tailscale; check the LAN rule in `ufw status` (live LAN test when the owner is home).
- [ ] **Step 7:** Before rebooting, verify `tailscaled` and `ssh` start at boot, the Tailscale node key is not near expiry, and Wi-Fi connects automatically. Reboot on approval; all containers and timers return. Second `make deploy` reports `changed=0`.
- [ ] **Step 8:** Stop heartbeat once and confirm Healthchecks alerts; re-enable.
- [ ] **Step 9:** Owner deletes the old tunnel `homeserver` in the dashboard; remove the archive on approval.
