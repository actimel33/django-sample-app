# Docker networking demo

Bridge, internal, host and overlay networks, shown with commands you can run one by
one. Measured on Docker Engine 29.6.1 under WSL2 (Linux).

| File | Covers |
|---|---|
| `docker-compose.yaml` | user-defined bridge, internal network, published port, host network |
| `overlay.sh` | overlay network |

## The setup

Four identical busybox web servers; only their networks differ.

```
frontend (bridge)                backend (bridge, internal)
web ---------- app ------------- app ---------- db
published on 127.0.0.1:8080      no route to the internet
```

`web` is on `frontend` only, `db` on `backend` only, `app` on both. `hostnet` is not
on any network: it uses the host's.

```bash
cd docs/networking
docker compose up -d
```

Ports 8080 and 9090 on the host must be free. Each server answers `/etc/hostname`
with its own container id, so a reply shows who answered.

## Bridge: containers see each other by name, only inside a shared network

```bash
docker compose exec web wget -qO- http://app/etc/hostname   # works: web and app share frontend
docker compose exec web wget -qO- -T 3 http://db/etc/hostname
```

The first prints the id of `app` (compare with `docker compose ps -q app`). The
second fails, because `web` and `db` share no network:

```
wget: bad address 'db'
```

```bash
docker compose exec app wget -qO- http://db/etc/hostname    # works: app and db share backend
```

## Internal: no route to the internet

```bash
docker compose exec app wget -q -T 3 -O /dev/null http://1.1.1.1 2>/dev/null && echo reachable
docker compose exec db wget -q -T 3 -O /dev/null http://1.1.1.1
```

`app` prints `reachable`. `db` fails:

```
wget: can't connect to remote host (1.1.1.1): Network is unreachable
```

`app` is also on `backend`, but it keeps internet access through `frontend`:
`internal` is a property of the network, not of the container.

## Published port: how the outside reaches a container

```bash
curl http://127.0.0.1:8080/etc/hostname
```

Prints the id of `web`, the only service with `ports:`. It is bound to `127.0.0.1`, so
only this machine can reach it.

## Host: the container uses the host's network

```bash
curl http://127.0.0.1:9090/etc/hostname
hostname
```

Both print the same name (`Laptop` here). `hostnet` has no `ports:`, yet answers on
host port 9090: the port belongs to the host, and the container even reports the
host's name.

```bash
docker compose down
```

## Overlay: one network across engines

A regular engine refuses to create one:

```
$ docker network create -d overlay probe-overlay
Error response from daemon: This node is not a swarm manager. ...
```

`overlay.sh` runs `docker swarm init` on the engine you are connected to, creates an
overlay network with two services, asks one from the other by name, and leaves the
swarm when it exits (about 20 s). It stops if the engine is already in a swarm.

```bash
./overlay.sh
```

```
network: demo-overlay  driver: overlay  scope: swarm
container ov-a: 8fa976a11789
container ov-b: 09256a34bd40
ov-a asks http://ov-b/etc/hostname and gets: 09256a34bd40
```

`ov-a` reached `ov-b` by name and got `ov-b`'s container id. Everything runs on one
node, so this shows the overlay network and name resolution on it, not traffic
between separate hosts. I ran the script against a throwaway `docker:dind` engine
(`DOCKER_HOST=tcp://...`), where the swarm was `inactive` again afterwards.
