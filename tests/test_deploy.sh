#!/usr/bin/env bash
# Runs the playbook against the test VM and checks the resulting machine.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

if ! vm 'test -e apps'; then
  for value in unset empty; do
    if [ "$value" = unset ]; then
      if (unset BESZEL_KEY; play) >"$LOG" 2>&1; then fail "play succeeded with BESZEL_KEY unset"; fi
    else
      if BESZEL_KEY='' play >"$LOG" 2>&1; then fail "play succeeded with BESZEL_KEY empty"; fi
    fi
    grep -q BESZEL_KEY "$LOG" || fail "error does not name BESZEL_KEY ($value)"
    vm 'test ! -e apps && ! command -v docker' || fail "server changed although a secret is $value"
    pass "$value secret stops the play before any change"
  done
else
  skip "missing-secret checks need a fresh VM"
fi

play >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "first run"; }
pass "first run"
assert_unchanged_run
pass "second run changes nothing"

sleep 15
for container in beszel beszel-agent dozzle; do
  [ "$(vm "docker inspect -f '{{.State.Running}} {{.RestartCount}}' $container")" = "true 0" ] || fail "$container is not running steadily"
done
pass "containers running"
vm 'docker ps -a --format {{.Names}}' | grep -qx cloudflared && fail "skipped app was deployed"
pass "skipped app not deployed"
for port in 8090 8080; do
  listeners="$(vm "ss -Hltn 'sport = :$port'" | awk '{print $4}')"
  [ "$listeners" = "$VM_IP:$port" ] || fail "port $port listens on '$listeners'"
done
pass "ports bound to the bind IP only"
for file in apps/beszel/.env apps/dozzle/.env apps/dozzle/data/users.yml; do
  [ "$(vm "sudo stat -c %a $file")" = 600 ] || fail "$file is not mode 600"
done
vm 'sudo cat apps/dozzle/data/users.yml' | grep -qF "$DOZZLE_PASSWORD_HASH" || fail "password hash was altered"
pass "secret files protected and intact"
[ "$(vm 'systemctl is-enabled homeserver-heartbeat.timer')" = enabled ] || fail "heartbeat timer disabled"
vm 'test -x /usr/local/bin/thermal-log && ! systemctl is-enabled thermal-log.timer >/dev/null 2>&1' || fail "thermal timer must stay off without sensors"
pass "timers"
echo "ALL PASSED"
