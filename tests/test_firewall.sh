#!/usr/bin/env bash
# Checks that the firewall is opt-in, rolls itself back when it locks SSH out, and converges.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

ROLLBACK_SECONDS=60
CONFIRMED=(-e firewall_confirmed=true)

if ! vm 'sudo ufw show added' | grep -q '^ufw '; then
  play >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "run without confirmation"; }
  vm 'sudo ufw status' | grep -q 'Status: inactive' || fail "firewall enabled without confirmation"
  pass "firewall stays off without confirmation"

  if play --tags firewall "${CONFIRMED[@]}" -e lan_cidr=10.99.99.0/24 -e vpn_interface=unused0 \
    -e firewall_rollback_seconds="$ROLLBACK_SECONDS" -e firewall_verify_timeout=20 >"$LOG" 2>&1; then
    fail "play succeeded although the rules lock SSH out"
  fi
  grep -q 'Prove that a new SSH session still works' "$LOG" || { tail -30 "$LOG"; fail "play failed for another reason"; }
  vm true 2>/dev/null && fail "SSH was never blocked, so the rollback was not exercised"
  sleep "$ROLLBACK_SECONDS"
  vm 'sudo ufw status' | grep -q 'Status: inactive' || fail "rollback did not disable the firewall"
  pass "lockout is rolled back automatically"
else
  skip "opt-in and rollback checks need a VM without firewall rules"
fi

play "${CONFIRMED[@]}" >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "confirmed run"; }
status="$(vm 'sudo ufw status verbose')"
grep -q 'Status: active' <<<"$status" || fail "firewall is not active"
grep -q 'deny (incoming), allow (outgoing)' <<<"$status" || fail "wrong default policy"
grep -Eq 'Anywhere on tailscale0 +ALLOW IN' <<<"$status" || fail "VPN interface is not allowed"
grep -Eq '22/tcp +ALLOW IN +192\.168\.252\.0/24' <<<"$status" || fail "SSH from the LAN is not allowed"
pass "firewall rules"
vm 'systemctl list-timers --all' | grep -q ufw-rollback && fail "rollback timer is still pending"
pass "rollback timer cancelled"
assert_unchanged_run "${CONFIRMED[@]}"
pass "repeated run changes nothing"
echo "ALL PASSED"
