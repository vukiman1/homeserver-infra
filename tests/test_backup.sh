#!/usr/bin/env bash
# Checks backup, restore and their failure paths against a local restic repository on the test VM.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

CANARY=apps/dozzle/data/canary
BACKUP_PATH="/home/ubuntu/$CANARY"

restore_play() {
  ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/test.yml ansible/restore.yml "$@"
}
deploy_backup() { play --tags backup "$@" >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "deploying the backup role"; }; }
canary_sum() { vm "sudo sha256sum $CANARY" | cut -d' ' -f1; }
write_canary() { vm "head -c 4096 /dev/urandom | sudo tee $CANARY >/dev/null"; }
timer_state() { vm 'systemctl is-enabled homeserver-backup.timer' || true; }
stub_requests() { vm 'sudo journalctl -u hc-stub --no-pager' | grep -c "GET $1 " || true; }
assert_containers_running() {
  for container in beszel beszel-agent dozzle; do
    [ "$(vm "docker inspect -f '{{.State.Running}}' $container")" = true ] || fail "$container left stopped"
  done
}

play >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "deploy"; }
vm 'systemctl is-active -q hc-stub || sudo systemd-run --quiet --unit=hc-stub python3 -u -m http.server 9999 --bind 127.0.0.1'
write_canary

if ! vm 'sudo test -e /var/lib/homeserver/backup-enabled'; then
  [ "$(timer_state)" = disabled ] || fail "backup timer enabled before initialisation"
  pass "timer stays off until initialised"

  before="$(canary_sum)"
  RESTIC_REPOSITORY=/var/lib/homeserver-empty-repo deploy_backup
  if restore_play -e restore_apply=true -e restore_confirm=yes >"$LOG" 2>&1; then
    fail "restore from an empty repository succeeded"
  fi
  grep -q 'no usable snapshot' "$LOG" || { tail -30 "$LOG"; fail "empty repository error is unclear"; }
  [ "$(canary_sum)" = "$before" ] || fail "live data changed by a failed restore"
  [ "$(timer_state)" = disabled ] || fail "failed restore enabled the timer"
  assert_containers_running
  pass "restore from an empty repository fails safely"
  deploy_backup
else
  skip "checks that need an uninitialised machine"
fi

deploy_backup -e backup_init=true
[ "$(timer_state)" = enabled ] || fail "initialisation did not enable the timer"
pass "initialisation enables the timer"

successes="$(stub_requests /backup)"
vm 'sudo systemctl start homeserver-backup.service' || fail "backup run"
assert_containers_running
[ "$(stub_requests /backup)" -gt "$successes" ] || fail "success was not reported"
pass "backup succeeds and reports it"

saved="$(canary_sum)"
restore_play >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "restore to a temporary directory"; }
target="$(grep -o '/var/tmp/homeserver-restore\.[A-Za-z0-9]*' "$LOG" | head -1)"
[ "$(vm "sudo sha256sum $target$BACKUP_PATH" | cut -d' ' -f1)" = "$saved" ] || fail "restored file differs"
pass "restore to a temporary directory matches the source"

write_canary
changed="$(canary_sum)"
restore_play -e restore_apply=true -e restore_confirm=y >"$LOG" 2>&1 && fail "restore applied without 'yes'"
[ "$(canary_sum)" = "$changed" ] || fail "live data changed without confirmation"
pass "applying a restore requires 'yes'"

restore_play -e restore_apply=true -e restore_confirm=yes >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "applied restore"; }
[ "$(canary_sum)" = "$saved" ] || fail "applied restore did not bring the data back"
vm "sudo sh -c 'ls -d apps/dozzle/data.pre-restore-*'" >/dev/null || fail "previous data was not kept"
assert_containers_running
pass "confirmed restore replaces the data and keeps the previous copy"

failures="$(stub_requests /backup/fail)"
RESTIC_PASSWORD=wrong-password deploy_backup
vm 'sudo systemctl start homeserver-backup.service' 2>/dev/null && fail "backup with a wrong password succeeded"
assert_containers_running
[ "$(stub_requests /backup/fail)" -gt "$failures" ] || fail "failure was not reported"
deploy_backup
pass "failed backup restarts containers and reports it"

failures="$(stub_requests /backup/fail)"
vm 'mkdir -p slow-bin && printf "#!/bin/sh\nexec sleep 120\n" > slow-bin/restic && chmod +x slow-bin/restic'
vm 'sudo systemd-run --quiet --collect --unit=slow-backup --setenv=PATH=/home/ubuntu/slow-bin:/usr/sbin:/usr/bin:/sbin:/bin /usr/local/bin/homeserver-backup'
for _ in $(seq 1 30); do
  [ "$(vm "docker inspect -f '{{.State.Running}}' dozzle")" = false ] && break
  sleep 1
done
[ "$(vm "docker inspect -f '{{.State.Running}}' dozzle")" = false ] || fail "slow backup never stopped the containers"
vm 'sudo systemctl stop slow-backup'
assert_containers_running
[ "$(stub_requests /backup/fail)" -gt "$failures" ] || fail "interruption was not reported"
pass "interrupted backup restarts containers and reports it"

running() { vm "docker inspect -f '{{.State.Running}}' dozzle"; }
start_killed_backup() {
  vm 'sudo systemctl reset-failed slow-backup 2>/dev/null; sudo systemd-run --quiet --collect --unit=slow-backup --setenv=PATH=/home/ubuntu/slow-bin:/usr/sbin:/usr/bin:/sbin:/bin /usr/local/bin/homeserver-backup'
  for _ in $(seq 1 30); do
    [ "$(running)" = false ] && break
    sleep 1
  done
  vm 'sudo systemctl kill --signal=KILL slow-backup'
  sleep 3
  [ "$(running)" = false ] || fail "a killed backup should have left containers stopped"
}

[ "$(vm 'systemctl is-enabled homeserver-recover.service' || true)" = enabled ] || fail "recovery does not run at boot"
start_killed_backup
vm 'sudo systemctl start homeserver-recover.service' || fail "recovery run"
assert_containers_running
pass "boot recovery restarts containers left by a killed backup"

start_killed_backup
vm 'sudo systemctl start homeserver-backup.service' || fail "backup after a killed one"
assert_containers_running
pass "the next backup restarts containers left by a killed backup"

vm 'docker stop dozzle >/dev/null'
vm 'sudo systemctl start homeserver-recover.service'
[ "$(running)" = false ] || fail "recovery started a container that was stopped on purpose"
vm 'docker start dozzle >/dev/null'
pass "recovery leaves deliberately stopped containers alone"

assert_unchanged_run
pass "repeated run changes nothing"
echo "ALL PASSED"
