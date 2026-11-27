#!/usr/bin/env bash
# Rehearses the first run against a machine configured by hand like the real server.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# the real server runs every app, including the tunnel
ADOPT=(-e '{"apps_skip": []}')

if ! vm 'test -e apps'; then
  if (unset BESZEL_KEY; play "${ADOPT[@]}") >"$LOG" 2>&1; then fail "play succeeded with BESZEL_KEY unset"; fi
  if BESZEL_KEY='' play "${ADOPT[@]}" >"$LOG" 2>&1; then fail "play succeeded with BESZEL_KEY empty"; fi
  vm 'test ! -e apps && ! command -v docker' || fail "machine changed although a secret is empty"
  pass "missing secret stops the play before any change"
  vm "bash -s -- '$VM_IP' '$BESZEL_KEY'" <tests/legacy_state.sh >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "building the legacy state"; }
  sleep 10
  vm 'echo adoption-canary | sudo tee apps/beszel/beszel_data/canary >/dev/null'
fi
vm 'test ! -e /etc/homeserver' || fail "needs a VM that this repository has not configured yet"

database_before="$(vm 'sudo stat -c %i apps/beszel/beszel_data/data.db')"
docker_started="$(vm 'systemctl show docker -p ActiveEnterTimestampMonotonic --value')"

play "${ADOPT[@]}" --check --diff >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "check mode on the legacy machine"; }
vm 'test ! -e /etc/homeserver && test ! -e apps/dozzle' || fail "check mode changed the machine"
pass "check mode succeeds and changes nothing"

play "${ADOPT[@]}" >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "first deploy"; }
sleep 15
[ "$(vm 'sudo cat apps/beszel/beszel_data/canary')" = adoption-canary ] || fail "Beszel data lost"
[ "$(vm 'sudo stat -c %i apps/beszel/beszel_data/data.db')" = "$database_before" ] || fail "Beszel database replaced"
mounted="$(vm "docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' beszel")"
grep -q '/apps/beszel/beszel_data' <<<"$mounted" || fail "Beszel uses another data directory"
[ "$(vm "docker inspect -f '{{.State.Running}} {{.RestartCount}}' beszel")" = "true 0" ] || fail "Beszel is not running steadily"
vm "docker inspect -f '{{json .NetworkSettings.Networks}}' beszel" | grep -q '"tunnel"' || fail "Beszel did not join the tunnel network"
[ "$(vm "docker inspect -f '{{.Config.Image}}' cloudflared")" != cloudflare/cloudflared:latest ] || fail "cloudflared kept the old compose file"
[ "$(vm 'systemctl show docker -p ActiveEnterTimestampMonotonic --value')" = "$docker_started" ] || fail "Docker was restarted"
pass "legacy apps are adopted with their data and without a Docker restart"
# cloudflared restart-loops on the dummy token, which Compose reports as a change, so it is left out here
assert_unchanged_run
pass "repeated run changes nothing"
play "${ADOPT[@]}" --check >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "check mode after adoption"; }
pass "check mode succeeds after adoption"
echo "ALL PASSED"
