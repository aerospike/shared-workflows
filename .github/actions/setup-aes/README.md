# Setup Aerospike Enterprise Server

GitHub Action that starts one or more Aerospike Enterprise Server containers with optional clustering, TLS, and custom configuration.

## Prerequisites

- JFrog OIDC credentials (`oidc-provider` and `oidc-audience`) for pulling the AES Docker image
- A valid `features.conf` for enterprise features (e.g., multi-node clustering requires `asdb-cluster-nodes-limit 0`)

## Quick Start

### Single node

```yaml
- uses: ./.github/actions/setup-aes
  with:
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Multi-node cluster

A features file with `asdb-cluster-nodes-limit 0` is required for clustering.

```yaml
- uses: ./.github/actions/setup-aes
  with:
    num-nodes: "3"
    features-content: ${{ secrets.AES_FEATURES_CONF }}
    startup-timeout: "60"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

### Single node with TLS

```yaml
- uses: ./.github/actions/setup-aes
  with:
    enable-tls: "true"
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}
```

## Inputs

| Input                   | Required | Default                                                 | Description                                                                                 |
| ----------------------- | -------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `oidc-provider`         | Yes      |                                                         | JFrog OIDC provider name                                                                    |
| `oidc-audience`         | Yes      |                                                         | JFrog OIDC audience                                                                         |
| `server-tag`            | No       | `latest`                                                | AES Docker image tag                                                                        |
| `num-nodes`             | No       | `1`                                                     | Number of cluster nodes                                                                     |
| `container-name-prefix` | No       | `aerospike`                                             | Container name prefix (nodes: `prefix-1`, `prefix-2`, ...)                                  |
| `features-file`         | No       |                                                         | Path to `features.conf` on the runner                                                       |
| `features-content`      | No       |                                                         | Raw `features.conf` content (e.g., from a secret). Ignored if `features-file` is set        |
| `config-file`           | No       |                                                         | Path to `aerospike.conf` on the runner                                                      |
| `config-content`        | No       |                                                         | Raw `aerospike.conf` content. Ignored if `config-file` is set                               |
| `env-vars`              | No       |                                                         | Semicolon-delimited `KEY=VALUE` pairs passed as `-e` flags. Use `\;` for literal semicolons |
| `network-name`          | No       | `aerospike-net`                                         | Docker network name                                                                         |
| `base-port`             | No       | `3000`                                                  | Base host port (node N maps to `base-port + N - 1`)                                         |
| `service-port`          | No       | `3000`                                                  | Aerospike service port inside the container (must match `aerospike.conf`)                   |
| `startup-timeout`       | No       | `30`                                                    | Seconds to wait for node readiness and cluster formation                                    |
| `enable-tls`            | No       | `false`                                                 | Enable TLS on AES containers                                                                |
| `tls-base-port`         | No       | `4333`                                                  | Base host TLS port (node N maps to `tls-base-port + N - 1`)                                 |
| `container-repo-url`    | No       | `aerospike.jfrog.io`                                    | Docker registry hostname                                                                    |
| `server-type`           | No       | `database-docker-dev-local/aerospike-server-enterprise` | Image repository path                                                                       |
| `jfrog-platform-url`    | No       | `https://aerospike.jfrog.io`                            | JFrog platform URL                                                                          |

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
