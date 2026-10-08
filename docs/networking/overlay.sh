#!/usr/bin/env bash
# Overlay networks need swarm mode. This runs `docker swarm init` on the engine
# you are connected to, creates an overlay network with two services, and leaves
# the swarm on exit. One node is enough to create the network and see names
# resolve on it; it does not show traffic between separate hosts.
set -euo pipefail

if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != inactive ]; then
  echo "This engine is already part of a swarm, not touching it." >&2
  exit 1
fi

trap 'docker swarm leave --force >/dev/null 2>&1 || true' EXIT

addr=${ADVERTISE_ADDR:-$(ip route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')}
docker swarm init --advertise-addr "$addr" >/dev/null

docker network create --driver overlay demo-overlay >/dev/null
for name in ov-a ov-b; do
  docker service create --name "$name" --network demo-overlay busybox:1.37 \
    httpd -f -p 80 >/dev/null
done

until [ "$(docker service ls --format '{{.Replicas}}' | grep -c '^1/1$')" = 2 ]; do sleep 1; done

docker network ls --filter name=demo-overlay --format 'network: {{.Name}}  driver: {{.Driver}}  scope: {{.Scope}}'

a=$(docker ps -q --filter name=ov-a)
b=$(docker ps -q --filter name=ov-b)
echo "container ov-a: $a"
echo "container ov-b: $b"
echo "ov-a asks http://ov-b/etc/hostname and gets: $(docker exec "$a" wget -qO- -T 3 http://ov-b/etc/hostname)"
