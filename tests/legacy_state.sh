#!/usr/bin/env bash
# Runs on a blank test VM and recreates the hand-configured server as it was before this repository.
# usage: legacy_state.sh BIND_IP BESZEL_KEY
set -euo pipefail

bind_ip="$1"
beszel_key="$2"

. /etc/os-release
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
  "$VERSION_CODENAME" "$(dpkg --print-architecture)" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }\n}\n' | sudo tee /etc/docker/daemon.json >/dev/null
sudo systemctl restart docker
echo "net.ipv4.ip_nonlocal_bind=1" | sudo tee /etc/sysctl.d/90-nonlocal-bind.conf >/dev/null
sudo sysctl -q -p /etc/sysctl.d/90-nonlocal-bind.conf
sudo usermod -aG docker "$USER"

mkdir -p ~/apps/beszel ~/apps/cloudflared
cat >~/apps/beszel/compose.yaml <<YML
services:
  beszel:
    image: henrygd/beszel:latest
    container_name: beszel
    restart: unless-stopped
    ports:
      - "$bind_ip:8090:8090"
    environment:
      APP_URL: http://$bind_ip:8090
    volumes:
      - ./beszel_data:/beszel_data
      - ./beszel_socket:/beszel_socket

  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./beszel_agent_data:/var/lib/beszel-agent
      - ./beszel_socket:/beszel_socket
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      LISTEN: /beszel_socket/beszel.sock
      HUB_URL: http://$bind_ip:8090
      TOKEN: \${BESZEL_TOKEN:-}
      KEY: \${BESZEL_KEY:-}
YML
cat >~/apps/cloudflared/compose.yaml <<'YML'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${TUNNEL_TOKEN:?set TUNNEL_TOKEN in .env}
    networks:
      - tunnel

networks:
  tunnel:
    name: tunnel
YML
(
  umask 077
  printf 'BESZEL_TOKEN=legacy-token\nBESZEL_KEY="%s"\n' "$beszel_key" >~/apps/beszel/.env
  printf 'TUNNEL_TOKEN=legacy-tunnel-token\n' >~/apps/cloudflared/.env
)
sudo docker compose --project-directory ~/apps/beszel up -d --quiet-pull
sudo docker compose --project-directory ~/apps/cloudflared up -d --quiet-pull
