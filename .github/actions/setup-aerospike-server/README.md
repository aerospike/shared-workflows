# Setup Aerospike Enterprise Server

GitHub Action that starts one or more Aerospike Enterprise Server containers with optional clustering, TLS, security, strong consistency, and custom configuration.

## Prerequisites

- JFrog OIDC credentials (`oidc-provider` and `oidc-audience`) for pulling the AES Docker image
- A valid `features.conf` for enterprise features (e.g., multi-node clustering requires `asdb-cluster-nodes-limit 0`)

## Quick Start

### Single node

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Multi-node cluster

A features file with `asdb-cluster-nodes-limit 0` is required for clustering.

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    num-nodes: "3"
    features-content: ${{ secrets.AES_FEATURES_CONF }}
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
    features-content: ${{ secrets.AES_FEATURES_CONF }}
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Single node with strong consistency

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    enable-strong-consistency: "true"
    features-content: ${{ secrets.AES_FEATURES_CONF }}
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Multi-node with strong consistency

```yaml
- uses: ./.github/actions/setup-aerospike-server
  with:
    num-nodes: "3"
    enable-strong-consistency: "true"
    features-content: ${{ secrets.AES_FEATURES_CONF }}
    startup-timeout: "60"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

## Inputs

| Input                       | Required | Default                                                 | Description                                                                                   |
| --------------------------- | -------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `oidc-provider`             | Yes      |                                                         | JFrog OIDC provider name                                                                      |
| `oidc-audience`             | Yes      |                                                         | JFrog OIDC audience                                                                           |
| `server-tag`                | No       | `latest`                                                | AES Docker image tag                                                                          |
| `num-nodes`                 | No       | `1`                                                     | Number of cluster nodes                                                                       |
| `container-name-prefix`     | No       | `aerospike`                                             | Container name prefix (nodes: `prefix-1`, `prefix-2`, ...)                                    |
| `features-file`             | No       |                                                         | Path to `features.conf` on the runner                                                         |
| `features-content`          | No       |                                                         | Raw `features.conf` content (e.g., from a secret). Ignored if `features-file` is set          |
| `config-file`               | No       |                                                         | Path to `aerospike.conf` on the runner                                                        |
| `config-content`            | No       |                                                         | Raw `aerospike.conf` content. Ignored if `config-file` is set                                 |
| `env-vars`                  | No       |                                                         | Semicolon-delimited `KEY=VALUE` pairs passed as `-e` flags. Use `\;` for literal semicolons   |
| `network-name`              | No       | `aerospike-net`                                         | Docker network name                                                                           |
| `base-port`                 | No       | `3000`                                                  | Base host port (node N maps to `base-port + N - 1`)                                           |
| `service-port`              | No       | `3000`                                                  | Aerospike service port inside the container (must match `aerospike.conf`)                     |
| `startup-timeout`           | No       | `30`                                                    | Seconds to wait for node readiness and cluster formation                                      |
| `enable-tls`                | No       | `false`                                                 | Enable TLS on AES containers                                                                  |
| `tls-base-port`             | No       | `4333`                                                  | Base host TLS port (node N maps to `tls-base-port + N - 1`)                                   |
| `enable-security`           | No       | `false`                                                 | Enable Aerospike security (authentication with default admin/admin credentials)               |
| `enable-strong-consistency` | No       | `false`                                                 | Enable strong consistency on the `test` namespace. Implies security. Requires a features file |
| `tools-tag`                 | No       | `12.1.1_2`                                              | Aerospike tools Docker image tag                                                              |
| `container-repo-url`        | No       | `aerospike.jfrog.io`                                    | Docker registry hostname                                                                      |
| `server-container-repo`     | No       | `database-docker-dev-local/aerospike-server-enterprise` | Image repository path                                                                         |
| `jfrog-platform-url`        | No       | `https://aerospike.jfrog.io`                            | JFrog platform URL                                                                            |

## Outputs

| Output              | Description                                                                   |
| ------------------- | ----------------------------------------------------------------------------- |
| `container-names`   | Comma-separated container names (e.g., `aerospike-1,aerospike-2,aerospike-3`) |
| `network-name`      | Docker network name                                                           |
| `service-ports`     | Comma-separated host ports (e.g., `3000,3001,3002`)                           |
| `tls-service-ports` | Comma-separated TLS host ports (empty if TLS disabled)                        |
| `tls-cert-dir`      | Directory containing generated TLS certs (empty if TLS disabled)              |

## Multi-Node Clustering

For clusters (`num-nodes > 1`), the action:

- Generates a mesh heartbeat config with seed addresses for all nodes
- Bypasses the container entrypoint to prevent config overwrites
- Waits for all nodes to be ready, the cluster to form, and migrations to complete

If you provide a custom config via `config-file` or `config-content`, it must include a `heartbeat` section with `mode mesh`. The action will inject `mesh-seed-address-port` entries automatically.

## TLS

When `enable-tls: "true"`, the action generates a self-signed CA and server/client certificates. The certs are available at the path in the `tls-cert-dir` output:

- `ca.crt` / `ca.key` -- CA certificate and key
- `server.crt` / `server.key` -- server certificate and key
- `client.crt` / `client.key` -- client certificate and key

### Connecting from the runner host

Use the `tls-cert-dir` and `tls-service-ports` outputs to pass the certificates to any client running directly in a workflow step:

```yaml
- uses: ./.github/actions/setup-aerospike-server
  id: aes
  with:
    enable-tls: "true"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- name: Connect with TLS
  run: |
    aql --host 127.0.0.1 \
        --port ${{ steps.aes.outputs.tls-service-ports }} \
        --tls-enable \
        --tls-cafile ${{ steps.aes.outputs.tls-cert-dir }}/ca.crt \
        --tls-certfile ${{ steps.aes.outputs.tls-cert-dir }}/client.crt \
        --tls-keyfile ${{ steps.aes.outputs.tls-cert-dir }}/client.key \
        --tls-name aerospike-tls
```

### Example: Go client tests

Go clients accept PEM certificate files directly via command-line flags:

```yaml
- uses: ./.github/actions/setup-aerospike-server
  id: aes
  with:
    enable-tls: "true"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- name: Run tests with TLS
  run: |
    CERT_DIR="${{ steps.aes.outputs.tls-cert-dir }}"

    ginkgo -race -keep-going -- \
      -h 127.0.0.1 \
      -p ${{ steps.aes.outputs.tls-service-ports }} \
      -root_ca "$CERT_DIR/ca.crt" \
      -cert_file "$CERT_DIR/client.crt" \
      -key_file "$CERT_DIR/client.key" \
      -node_tls_name aerospike-tls
```

### Example: Java client tests with a trust store

Java clients require a JKS trust store rather than raw PEM files. Import the generated CA certificate into a trust store, then pass it to the test runner:

```yaml
- uses: ./.github/actions/setup-aerospike-server
  id: aes
  with:
    enable-tls: "true"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- name: Build client
  run: mvn clean install -DskipTests

- name: Create trust store and run tests
  working-directory: test
  run: |
    CERT_DIR="${{ steps.aes.outputs.tls-cert-dir }}"
    TRUSTSTORE="$CERT_DIR/truststore.jks"
    STOREPASS="changeit"

    keytool -import -noprompt \
      -alias aes-ca \
      -file "$CERT_DIR/ca.crt" \
      -keystore "$TRUSTSTORE" \
      -storepass "$STOREPASS"

    ./run_tests \
      -Djavax.net.ssl.trustStore="$TRUSTSTORE" \
      -Djavax.net.ssl.trustStorePassword="$STOREPASS" \
      -h "127.0.0.1:aerospike-tls:${{ steps.aes.outputs.tls-service-ports }}" \
      -tls
```

## Security

When `enable-security: "true"`, the action enables Aerospike's built-in authentication with the default `admin`/`admin` credentials. Clients must authenticate to connect.

- Default credentials: username `admin`, password `admin`
- The security stanza is automatically added to generated configs
- If you provide a custom config, the action appends the security stanza unless one is already present

## Strong Consistency

When `enable-strong-consistency: "true"`, the action configures the `test` namespace for strong consistency mode:

- **Implies security**: Authentication is auto-enabled (with a warning) if `enable-security` is not explicitly set
- **Requires a features file**: You must provide `features-file` or `features-content`
- **File-backed storage**: The namespace uses device storage (`/opt/aerospike/data/test.dat`, 4G) instead of memory storage, as required by SC
- **Replication factor**: Set to `min(num_nodes, 2)` -- RF=1 for single-node, RF=2 for multi-node
- **Automatic roster setup**: After the server is ready, the action runs `manage roster stage observed ns test` and `manage recluster` via the Aerospike tools container
- **SC-aware readiness check**: The wait script uses `asinfo cluster-stable:ignore-migrations=true` instead of log-based migration checks, since SC partitions won't complete migrations until the roster is configured

### Custom config with strong consistency

If you provide a custom config via `config-file` or `config-content` with SC enabled, the action will **not** inject SC namespace directives into your config (modifying arbitrary namespace blocks is fragile). You must include the SC settings in your config yourself. The security stanza will still be appended if missing.
