# Setup DNS Server

GitHub Action that serves one DNS zone to a Docker network, so clients can test DNS seed discovery (A, AAAA and SRV seeds) in CI. It is language and topology agnostic: you supply the network and the zone file text.

This action:

1. Starts [CoreDNS](https://coredns.io) on an existing Docker network with the [`file`](https://coredns.io/plugins/file/) plugin serving `zone-content` as `zone-name`
2. Waits until the server answers an SOA query for the zone from a container on that network
3. Fails with the CoreDNS container log if it does not (for example, when the zone file does not parse)

Clients on the same network query `server-address` on port 53 (UDP and TCP).

## Prerequisites

- The Docker network already exists (for example, `setup-aerospike-server`'s `network-name` output or `setup-discovery-topology`'s `client-network-name` output)
- `zone-content` includes an SOA record for `zone-name`

## Quick Start

### Next to setup-aerospike-server: an A record per node

```yaml
- uses: aerospike/shared-workflows/.github/actions/setup-aerospike-server@v3
  id: aerospike
  with:
    num-nodes: "3"
    publish-ports: "false"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- name: Build zone
  id: zone
  env:
    CONTAINER_NAMES: ${{ steps.aerospike.outputs.container-names }}
    NETWORK_NAME: ${{ steps.aerospike.outputs.network-name }}
  run: |
    {
      echo "zone-content<<EOF"
      echo '$ORIGIN aerospike.test.'
      echo "@ 3600 IN SOA ns.aerospike.test. admin.aerospike.test. 1 60 60 60 1"
      IFS=',' read -ra names <<<"$CONTAINER_NAMES"
      for name in "${names[@]}"; do
        ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NETWORK_NAME\").IPAddress}}" "$name")
        echo "$name 1 IN A $ip"
        echo "seeds 1 IN A $ip"
      done
      echo "EOF"
    } >>"$GITHUB_OUTPUT"

- uses: aerospike/shared-workflows/.github/actions/setup-dns-server@v3
  id: dns
  with:
    network-name: ${{ steps.aerospike.outputs.network-name }}
    zone-name: aerospike.test
    zone-content: ${{ steps.zone.outputs.zone-content }}

- run: |
    docker run --rm \
      --network ${{ steps.aerospike.outputs.network-name }} \
      my-client-image \
      run-tests --dns-server ${{ steps.dns.outputs.server-address }}:53 --dns-name seeds.aerospike.test
```

### With setup-discovery-topology: SRV records pointing at the proxy listeners

The DNS server joins the client network. Each SRV record targets the Toxiproxy address on that network, one record per listen port.

```yaml
- uses: aerospike/shared-workflows/.github/actions/setup-aerospike-server@v3
  id: aerospike
  with:
    num-nodes: "3"
    publish-ports: "false"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- uses: aerospike/shared-workflows/.github/actions/setup-discovery-topology@v3
  id: topology
  with:
    container-names: ${{ steps.aerospike.outputs.container-names }}
    aerospike-network-name: ${{ steps.aerospike.outputs.network-name }}

- name: Build zone
  id: zone
  env:
    CLIENT_NETWORK: ${{ steps.topology.outputs.client-network-name }}
    ENDPOINT_PORTS: ${{ steps.topology.outputs.endpoint-ports }}
    PROXY_CONTAINER: ${{ steps.topology.outputs.toxiproxy-container-name }}
  run: |
    proxy_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$CLIENT_NETWORK\").IPAddress}}" "$PROXY_CONTAINER")
    {
      echo "zone-content<<EOF"
      echo '$ORIGIN discovery.test.'
      echo "@ 3600 IN SOA ns.discovery.test. admin.discovery.test. 1 60 60 60 1"
      echo "proxy 1 IN A $proxy_ip"
      IFS=',' read -ra ports <<<"$ENDPOINT_PORTS"
      for port in "${ports[@]}"; do
        echo "_aerospike._tcp 1 IN SRV 10 10 $port proxy"
      done
      echo "EOF"
    } >>"$GITHUB_OUTPUT"

- uses: aerospike/shared-workflows/.github/actions/setup-dns-server@v3
  id: dns
  with:
    network-name: ${{ steps.topology.outputs.client-network-name }}
    zone-name: discovery.test
    zone-content: ${{ steps.zone.outputs.zone-content }}
```

The client, started with `docker run --network ${{ steps.topology.outputs.client-network-name }}`, looks up `_aerospike._tcp.discovery.test` SRV at `server-address` and reaches every node through `proxy.discovery.test:<listen-port>`.

## Changing records later in the job

The zone file is `/etc/coredns/db.<zone-name>` inside the container. The Corefile sets the `file` plugin's `reload 1s`, so CoreDNS checks the file every second and loads it when the **SOA serial is higher** than the one it serves. A rewrite that keeps the serial is ignored.

To change records, write the new zone with a higher serial and copy it into the container:

```yaml
- name: Move seeds to node-c
  env:
    CONTAINER_NAME: ${{ steps.dns.outputs.container-name }}
  run: |
    cat >"$RUNNER_TEMP/db.dns.test" <<'EOF'
    $ORIGIN dns.test.
    @ 3600 IN SOA ns.dns.test. admin.dns.test. 2 60 60 60 1
    _aerospike._tcp 1 IN SRV 10 10 3000 node-c
    node-c 1 IN A 192.0.2.13
    EOF
    docker cp "$RUNNER_TEMP/db.dns.test" "$CONTAINER_NAME:/etc/coredns/db.dns.test"
```

CoreDNS logs `Successfully reloaded zone "dns.test." ... with 2 SOA serial`, and answers with the new records within about a second. Keep record TTLs short (`1` above) so clients do not cache old answers.

The files are copied into the container with `docker cp` rather than bind-mounted from the runner. This works the same when the Docker daemon cannot see the runner's filesystem, for example a runner container with the Docker socket mounted.

## Inputs

Required inputs first.

| Input                    | Required | Default                                   | Description                                                      |
| ------------------------ | -------- | ----------------------------------------- | ---------------------------------------------------------------- |
| `network-name`           | Yes      |                                           | Existing Docker network to attach the DNS server to              |
| `zone-content`           | Yes      |                                           | Zone file text (RFC 1035 master file format, with an SOA record) |
| `zone-name`              | Yes      |                                           | Zone origin served by the DNS server (e.g. `dns.test`)           |
| `container-name`         | No       | `coredns`                                 | CoreDNS container name                                           |
| `coredns-image`          | No       | `coredns/coredns:1.11.3` pinned by digest | CoreDNS image                                                    |
| `enable-bash-trace-mode` | No       | `false`                                   | Print shell commands as they run                                 |
| `startup-timeout`        | No       | `30`                                      | Seconds to wait for the DNS server to answer the zone's SOA      |

## Outputs

| Output           | Description                                                       |
| ---------------- | ----------------------------------------------------------------- |
| `container-name` | CoreDNS container name                                            |
| `server-address` | IP address of the DNS server on `network-name` (port 53, UDP/TCP) |

## Running Tests

```bash
bats .github/actions/setup-dns-server/tests/
```
