# Setup Aerospike Server

GitHub Action that starts one or more Aerospike Server containers with optional clustering, TLS, security, strong consistency, and custom configuration.

## Prerequisites

- JFrog OIDC credentials (`oidc-provider` and `oidc-audience`) for pulling the Aerospike Server Docker image
- A valid `features.conf` for Enterprise-only features (e.g., Enterprise multi-node clustering requires `asdb-cluster-nodes-limit 0`)

## Quick Start

### Single node

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Multi-node cluster

A features file with `asdb-cluster-nodes-limit 0` is required for Enterprise clustering.

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    num-nodes: "3"
    features-content: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF }}
    startup-timeout: "60"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Single node with TLS

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    enable-tls: "true"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Single node with security

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    enable-security: "true"
    features-content: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF }}
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Single node with strong consistency

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    enable-strong-consistency: "true"
    features-content: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF }}
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Multi-node with strong consistency

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    num-nodes: "3"
    enable-strong-consistency: "true"
    features-content: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF }}
    startup-timeout: "60"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Community edition

Set `server-container-repo` to the Community image repository. The action will omit Enterprise-only `feature-key-file` config, remove that directive from custom configs, and ignore `features-file` / `features-content`.

With `server-edition: auto`, the action infers `enterprise` from repositories named `aerospike-server-enterprise` and `community` from repositories named `aerospike-server`. If you use a mirror or custom repository name, set `server-edition` explicitly.

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    server-container-repo: database-docker-virtual/aerospike-server
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

## Inputs

| Input                          | Required | Default                                               | Description                                                                                 |
| ------------------------------ | -------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `oidc-provider`                | Yes      |                                                       | JFrog OIDC provider name                                                                    |
| `oidc-audience`                | Yes      |                                                       | JFrog OIDC audience                                                                         |
| `server-tag`                   | No       | `latest`                                              | Aerospike Server Docker image tag                                                           |
| `num-nodes`                    | No       | `1`                                                   | Number of cluster nodes                                                                     |
| `start-nodes`                  | No       | `num-nodes`                                           | Start only the first N nodes. See [Starting nodes later](#starting-nodes-later)             |
| `container-name-prefix`        | No       | `aerospike`                                           | Container name prefix (nodes: `prefix-1`, `prefix-2`, ...)                                  |
| `features-file`                | No       |                                                       | Path to `features.conf` on the runner                                                       |
| `features-content`             | No       |                                                       | Raw `features.conf` content (e.g., from a secret). Ignored if `features-file` is set        |
| `config-file`                  | No       |                                                       | Path to `aerospike.conf` on the runner. See [Per-node config](#per-node-config)             |
| `config-content`               | No       |                                                       | Raw `aerospike.conf` content. Ignored if `config-file` is set                               |
| `env-vars`                     | No       |                                                       | Semicolon-delimited `KEY=VALUE` pairs passed as `-e` flags. Use `\;` for literal semicolons |
| `extra-hosts`                  | No       |                                                       | Comma-separated `name:ip` entries passed as `--add-host` to every node                      |
| `network-name`                 | No       | `aerospike-net`                                       | Docker network name                                                                         |
| `network-subnet`               | No       |                                                       | IPv4 /24 subnet, a fixed IP per node. See [Starting nodes later](#starting-nodes-later)     |
| `base-port`                    | No       | `3000`                                                | Base host port (node N maps to `base-port + N - 1`)                                         |
| `service-port`                 | No       | `3000`                                                | Aerospike service port inside the container (must match `aerospike.conf`)                   |
| `publish-ports`                | No       | `true`                                                | Publish container ports to the runner host. Set `false` for L2 discovery topologies         |
| `startup-timeout`              | No       | `30`                                                  | Seconds to wait for node readiness and cluster formation                                    |
| `enable-tls`                   | No       | `false`                                               | Enable TLS on Aerospike Server containers                                                   |
| `tls-base-port`                | No       | `4333`                                                | Base host TLS port (node N maps to `tls-base-port + N - 1`)                                 |
| `tls-cert-cn`                  | No       | `aerospike-tls`                                       | Common Name on the generated server certificate                                             |
| `include-tls-name-san`         | No       | `true`                                                | Include `aerospike-tls` as a DNS SAN. Set `false` to leave it only in the CN                |
| `enable-security`              | No       | `false`                                               | Enable Aerospike security (authentication with default admin/admin credentials)             |
| `enable-strong-consistency`    | No       | `false`                                               | Enable strong consistency on the `test` namespace. Requires a features file                 |
| `sc-stability-timeout-seconds` | No       | `30`                                                  | Seconds to wait for SC cluster stability after roster setup                                 |
| `tools-tag`                    | No       | `12.1.1_2`                                            | Aerospike tools Docker image tag                                                            |
| `container-repo-url`           | No       | `aerospike.jfrog.io`                                  | Docker registry hostname                                                                    |
| `server-container-repo`        | No       | `database-docker-virtual/aerospike-server-enterprise` | Image repository path                                                                       |
| `server-edition`               | No       | `auto`                                                | Server edition: `auto`, `enterprise`, or `community`; set explicitly for custom repo names  |
| `jfrog-platform-url`           | No       | `https://aerospike.jfrog.io`                          | JFrog platform URL                                                                          |

## Outputs

| Output              | Description                                                                   |
| ------------------- | ----------------------------------------------------------------------------- |
| `container-names`   | Comma-separated container names (e.g., `aerospike-1,aerospike-2,aerospike-3`) |
| `network-name`      | Docker network name                                                           |
| `service-ports`     | Comma-separated host ports (e.g., `3000,3001,3002`)                           |
| `tls-service-ports` | Comma-separated TLS host ports (empty if TLS disabled)                        |
| `tls-cert-dir`      | Directory containing generated TLS certs (empty if TLS disabled)              |

When `publish-ports` is `false`, the action still reports `service-ports` / `tls-service-ports` as the calculated host-port numbers, but it does not bind them. Use this for L2 discovery tests so a client running on the runner cannot connect through localhost mappings. Isolation from node IPs still requires running the client in a container that is not on the Aerospike network.

## Multi-Node Clustering

For clusters (`num-nodes > 1`), the action:

- Generates a mesh heartbeat config with seed addresses for all nodes
- When `enable-tls` is set and no custom config is provided, includes the TLS listener (`tls-name aerospike-tls`, `tls-port 4333`) in that same config, with replication-factor 2
- Bypasses the container entrypoint to prevent config overwrites
- Waits for all nodes to be ready, the cluster to form, and migrations to complete

Every node's mesh seed list names all `num-nodes` nodes, including any not started yet. See [Starting nodes later](#starting-nodes-later).

If you provide a custom config via `config-file` or `config-content`, it must include a `heartbeat` section with `mode mesh`. The action will inject `mesh-seed-address-port` entries automatically.

For `server-edition: enterprise`, the action requires `features-file` or `features-content` for multi-node clusters. When either is set, the action mounts that file and, if the custom config does not already contain `feature-key-file`, injects that directive pointing at the mounted path. An existing `feature-key-file` directive is left unchanged. For `server-edition: community`, it does not render or mount a features file because `feature-key-file` is Enterprise-only, and it removes that directive from custom configs.

## Starting nodes later

`start-nodes: K` starts only nodes 1 to K. Nodes K+1 to `num-nodes` are created with `docker create`, with the same arguments and per-node config, so a later step can `docker start` them or use them as a template. The readiness wait covers the started nodes and waits for a cluster of exactly K nodes. With `enable-strong-consistency`, the roster is set from those K nodes.

The mesh seeds of a node that is not running do not resolve. The server logs `Error while converting address 'aerospike-3': Name or service not known`, keeps retrying, and forms a cluster from the seeds that answer. A node started later joins through its own seeds.

`network-subnet: a.b.c.0/24` creates the network with that subnet and gives node N the fixed IP `a.b.c.(N + 1)`, started or not, so `172.30.0.0/24` puts three nodes on `172.30.0.2` to `172.30.0.4`. Without it, Docker assigns an IP when a node starts, and a restarted node can get a different one.

```yaml
- uses: aerospike/shared-workflows/.github/actions/setup-aerospike-server@v3
  with:
    num-nodes: "4"
    start-nodes: "3"
    network-subnet: 172.30.0.0/24
    features-content: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF }}
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
# Tests against 3 nodes, then: docker start aerospike-4
```

## Per-node config

Each node gets its own copy of the config, mounted at `/etc/aerospike-custom/<container-name>.conf`. Before copying, the action replaces two tokens in the generated config and in `config-file` / `config-content`:

- `{{NODE_INDEX}}` -- the 1-based node number, matching `<container-name-prefix>-N`
- `{{NODE_NAME}}` -- the container name, e.g. `aerospike-2`

This is plain string replacement. Nothing else in your config is expanded, so `$VAR`, `${VAR}`, and `$(...)` are written as-is. A config without tokens is copied unchanged to every node.

Advertise a different `alternate-access-port` on each node (3100, 3200, 3300):

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    num-nodes: "3"
    server-container-repo: database-docker-virtual/aerospike-server
    config-content: |
      service {
          cluster-name docker
          proto-fd-max 15000
      }

      logging {
          console {
              context any info
          }
      }

      network {
          service {
              address any
              port 3000
              alternate-access-address {{NODE_NAME}}
              alternate-access-port 3{{NODE_INDEX}}00
          }
          heartbeat {
              mode mesh
              address any
              port 3002
          }
          fabric {
              address any
              port 3001
          }
      }

      namespace test {
          replication-factor 2
          storage-engine memory {
              data-size 1G
          }
      }
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

`asinfo -v service-clear-alt` on `aerospike-2` then returns `<address>:3200`. The server only advertises alternate endpoints when `alternate-access-address` is set.

Put each node in its own rack by setting `rack-id` in the namespace:

```yaml
config-content: |
  # service, logging, and network stanzas as above
  namespace test {
      replication-factor 2
      rack-id {{NODE_INDEX}}
      storage-engine memory {
          data-size 1G
      }
  }
```

## Extra hosts

`extra-hosts` takes comma-separated `name:ip` entries and passes each one to `docker run --add-host` on every node, so the names resolve inside the containers. The IP can be IPv4, IPv6, or `host-gateway`. `docker run` rejects an entry with an invalid IP.

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    num-nodes: "2"
    extra-hosts: db.example:10.0.0.5,cache.example:10.0.0.6
    features-content: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF }}
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

## TLS

When `enable-tls: "true"`, the action generates a self-signed CA and server/client certificates. The certs are available at the path in the `tls-cert-dir` output:

- `ca.crt` / `ca.key` -- CA certificate and key
- `server.crt` / `server.key` -- server certificate and key
- `client.crt` / `client.key` -- X.509 v3 client certificate and key (`basicConstraints=CA:FALSE`, `extendedKeyUsage=clientAuth`)

`server.crt` is valid for each container name (`<container-name-prefix>-N`), `localhost`, `docker`, and `127.0.0.1`. By default it is also valid for `aerospike-tls`: that name is both the certificate CN and a DNS SAN, and it is the `tls-name` in the generated config.

`tls-cert-cn` and `include-tls-name-san` change that shape without changing the server `tls-name`. Other SANs stay in place.

SAN-only tls-name (the CN does not match), for a client that requires the name in a dNSName SAN:

```yaml
enable-tls: "true"
tls-cert-cn: not-the-tls-name
include-tls-name-san: "true"
```

CN-only tls-name (no DNS SAN for `aerospike-tls`):

```yaml
enable-tls: "true"
include-tls-name-san: "false"
```

The connection examples below assume the default shape, where `aerospike-tls` is both the CN and a DNS SAN.

### Connecting from the runner host

Use the `tls-cert-dir` and `tls-service-ports` outputs to pass the certificates to any client running directly in a workflow step:

```yaml
- uses: ./.github/actions/setup-aerospike-server
  id: aerospike-server
  with:
    enable-tls: "true"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- name: Connect with TLS
  run: |
    aql --host 127.0.0.1 \
        --port ${{ steps.aerospike-server.outputs.tls-service-ports }} \
        --tls-enable \
        --tls-cafile ${{ steps.aerospike-server.outputs.tls-cert-dir }}/ca.crt \
        --tls-certfile ${{ steps.aerospike-server.outputs.tls-cert-dir }}/client.crt \
        --tls-keyfile ${{ steps.aerospike-server.outputs.tls-cert-dir }}/client.key \
        --tls-name aerospike-tls
```

### Example: Go client tests

Go clients accept PEM certificate files directly via command-line flags:

```yaml
- uses: ./.github/actions/setup-aerospike-server
  id: aerospike-server
  with:
    enable-tls: "true"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- name: Run tests with TLS
  run: |
    CERT_DIR="${{ steps.aerospike-server.outputs.tls-cert-dir }}"

    ginkgo -race -keep-going -- \
      -h 127.0.0.1 \
      -p ${{ steps.aerospike-server.outputs.tls-service-ports }} \
      -root_ca "$CERT_DIR/ca.crt" \
      -cert_file "$CERT_DIR/client.crt" \
      -key_file "$CERT_DIR/client.key" \
      -node_tls_name aerospike-tls
```

### Example: Java client tests with a trust store

Java clients require a JKS trust store rather than raw PEM files. Import the generated CA certificate into a trust store, then pass it to the test runner:

```yaml
- uses: ./.github/actions/setup-aerospike-server
  id: aerospike-server
  with:
    enable-tls: "true"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- name: Build client
  run: mvn clean install -DskipTests

- name: Create trust store and run tests
  working-directory: test
  run: |
    CERT_DIR="${{ steps.aerospike-server.outputs.tls-cert-dir }}"
    TRUSTSTORE="$CERT_DIR/truststore.jks"
    STOREPASS="changeit"

    keytool -import -noprompt \
      -alias aerospike-server-ca \
      -file "$CERT_DIR/ca.crt" \
      -keystore "$TRUSTSTORE" \
      -storepass "$STOREPASS"

    ./run_tests \
      -Djavax.net.ssl.trustStore="$TRUSTSTORE" \
      -Djavax.net.ssl.trustStorePassword="$STOREPASS" \
      -h "127.0.0.1:aerospike-tls:${{ steps.aerospike-server.outputs.tls-service-ports }}" \
      -tls
```

## Security

When `enable-security: "true"`, the action enables Aerospike's built-in authentication with the default `admin`/`admin` credentials. Clients must authenticate to connect.

- Default credentials: username `admin`, password `admin`
- The security stanza is automatically added to generated configs
- If you provide a custom config, the action appends the security stanza unless one is already present

## Strong Consistency

When `enable-strong-consistency: "true"`, the action configures the `test` namespace for strong consistency mode:

- **Requires a features file**: You must provide `features-file` or `features-content`
- **File-backed storage**: The namespace uses device storage (`/opt/aerospike/data/test.dat`, 4G) instead of memory storage, as required by SC
- **Replication factor**: Set to `min(num_nodes, 2)` -- RF=1 for single-node, RF=2 for multi-node
- **Automatic roster setup**: After the server is ready, the action runs `manage roster stage observed ns test` and `manage recluster` via the Aerospike tools container
- **SC-aware readiness check**: The wait script uses `asinfo cluster-stable:ignore-migrations=true` instead of log-based migration checks, since SC partitions won't complete migrations until the roster is configured

### Custom config with strong consistency

If you provide a custom config via `config-file` or `config-content` with SC enabled, the action will **not** inject SC namespace directives into your config (modifying arbitrary namespace blocks is fragile). You must include the SC settings in your config yourself. The security stanza will still be appended if missing.
