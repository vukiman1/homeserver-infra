#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${VM_NAME:-homeserver-test}"
VM_IMAGE=26.04
STATE_DIR="$(cd "$(dirname "$0")/.." && pwd)/${VM_STATE_DIR:-.vm}"

up() {
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_DIR/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C "$VM_NAME" -f "$STATE_DIR/id_ed25519"
  if ! multipass info "$VM_NAME" >/dev/null 2>&1; then
    multipass launch "$VM_IMAGE" --name "$VM_NAME" --cpus 2 --memory 2G --disk 15G
  fi
  # the key goes in as an argument: `multipass exec` hangs on redirected stdin
  multipass exec "$VM_NAME" -- sh -c 'grep -qxF "$1" .ssh/authorized_keys || echo "$1" >>.ssh/authorized_keys' sh "$(cat "$STATE_DIR/id_ed25519.pub")" </dev/null
  multipass info "$VM_NAME" --format json |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["info"][sys.argv[1]]["ipv4"][0])' "$VM_NAME" >"$STATE_DIR/ip"
}

down() {
  if multipass info "$VM_NAME" >/dev/null 2>&1; then
    multipass delete --purge "$VM_NAME"
  fi
  rm -f "$STATE_DIR/ip"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
