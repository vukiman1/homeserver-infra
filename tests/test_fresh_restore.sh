#!/usr/bin/env bash
# Rebuilds a blank machine from the test VM's backup repository.
set -euo pipefail
cd "$(dirname "$0")/.."

source_vm() { (VM_STATE_DIR=.vm; . tests/lib.sh; vm "$@"); }

export VM_STATE_DIR=.vm-fresh
# shellcheck source=tests/lib.sh
. tests/lib.sh

vm '! command -v docker >/dev/null' || fail "needs a blank VM (homeserver-fresh already has Docker)"

if RESTIC_REPOSITORY=/var/lib/homeserver-empty-repo play -e restore_first=true >"$LOG" 2>&1; then
  fail "deploy succeeded without anything to restore"
fi
grep -q 'no usable snapshot' "$LOG" || { tail -30 "$LOG"; fail "deploy failed for another reason"; }
[ -z "$(vm 'sudo docker ps -aq')" ] || fail "apps started although the restore failed"
pass "apps do not start when there is nothing to restore"

source_vm 'sudo tar -C /var/lib -cf - homeserver-test-repo' | vm 'sudo tar -C /var/lib -xf -'
expected="$(source_vm 'sudo sha256sum apps/dozzle/data/canary' | cut -d' ' -f1)"

play -e restore_first=true >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "rebuild"; }
[ "$(vm 'sudo sha256sum apps/dozzle/data/canary' | cut -d' ' -f1)" = "$expected" ] || fail "restored data differs"
sleep 15
for container in beszel beszel-agent dozzle; do
  [ "$(vm "docker inspect -f '{{.State.Running}} {{.RestartCount}}' $container")" = "true 0" ] || fail "$container is not running steadily"
done
[ "$(vm 'systemctl is-enabled homeserver-backup.timer')" = enabled ] || fail "backup timer not enabled after restore"
pass "blank machine is rebuilt with its data"
assert_unchanged_run -e restore_first=true
pass "repeated run changes nothing"
echo "ALL PASSED"
