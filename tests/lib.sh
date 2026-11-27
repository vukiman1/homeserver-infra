# Shared helpers for the tests that run against the test VM.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VM_STATE_DIR="${VM_STATE_DIR:-.vm}"
VM_IP="$(cat "$VM_STATE_DIR/ip")"
VM_KEY="$PWD/$VM_STATE_DIR/id_ed25519"
export VM_IP VM_KEY
set -a
# shellcheck disable=SC1091
. tests/vm.env
set +a

LOG="$VM_STATE_DIR/ansible.log"

play() { ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/test.yml ansible/site.yml "$@"; }
vm() {
  ssh -i "$VM_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=5 -o BatchMode=yes "ubuntu@$VM_IP" "$@"
}
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
skip() {
  [ -z "${REQUIRE_FRESH:-}" ] || fail "would skip: $*"
  echo "skip: $*"
}
assert_unchanged_run() {
  play "$@" >"$LOG" 2>&1 || { tail -30 "$LOG"; fail "repeated run"; }
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$LOG" || { grep -B2 '^changed:' "$LOG"; fail "repeated run changed something"; }
}
