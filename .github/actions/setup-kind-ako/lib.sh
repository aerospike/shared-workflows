#!/usr/bin/env bash
# Pure helpers for setup-kind-ako. No kubectl, helm, or kind side effects.
# shellcheck disable=SC2034

# The Kubernetes default, so NodePorts are allocated as on a managed cluster.
NODEPORT_START=30000
NODEPORT_END=32767
NODEPORT_RANGE="${NODEPORT_START}-${NODEPORT_END}"

INGRESS_PORT_BASE=9000
SERVICE_PORT=3000
ENDPOINT_HOSTNAME="as-endpoint.test"
CLUSTER_NAME="aerocluster"
CLUSTER_NAMESPACE="aerospike"
AKO_NAMESPACE="ako"
INGRESS_NAMESPACE="ingress-nginx"
STARTUP_TIMEOUT=300
AKO_CHART_VERSION="4.5.0"
AKO_HELM_REPO="https://aerospike.github.io/aerospike-kubernetes-enterprise"
CERT_MANAGER_CHART_VERSION="v1.21.3"
CERT_MANAGER_HELM_REPO="https://charts.jetstack.io"
INGRESS_NGINX_CHART_VERSION="4.15.1"
INGRESS_NGINX_HELM_REPO="https://kubernetes.github.io/ingress-nginx"
ALTERNATE_ACCESS_LABEL="aerospike.com/configured-alternate-access-address"
CORE_DNS_MARKER="# setup-kind-ako endpoint"

error() {
    echo "Error: ${1-}" >&2
    exit 1
}

validate_cluster_size() {
    [[ $1 =~ ^[1-8]$ ]] || error "cluster-size must be 1-8 (got: '$1')"
}

validate_image_ref() {
    [[ $1 =~ ^[A-Za-z0-9._:/@-]+$ ]] ||
        error "server-image contains characters that are not valid in an image reference (got: '$1')"
}

ingress_ports() {
    local size=$1
    local i
    validate_cluster_size "$size"
    for ((i = 0; i < size; i++)); do
        printf '%s\n' "$((INGRESS_PORT_BASE + i))"
    done
}

pod_service_name() {
    printf '%s-0-%s\n' "$CLUSTER_NAME" "$1"
}

nodeport_probe_expectation() {
    if (($1 < NODEPORT_START || $1 > NODEPORT_END)); then
        printf 'reject\n'
    else
        printf 'accept\n'
    fi
}

render_kind_config() {
    # kind v0.33 emits kubeadm v1beta3, with extraArgs as a map, for every
    # Kubernetes version below 1.36. A v1beta4 list does not match that
    # document, so kubeadm never receives the flag. Keep this patch on
    # v1beta3 while the kind node image stays below v1.36.
    cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerPort: 6443
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        apiVersion: kubeadm.k8s.io/v1beta3
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            service-node-port-range: "${NODEPORT_RANGE}"
EOF
}

render_corefile_with_endpoint() {
    local corefile=$1
    local ip=$2
    local hosts_block line
    local -a kept=()
    local skipping=0
    local inserted=0

    [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || error "CoreDNS address is not an IP (got: '$ip')"

    hosts_block=$(
        cat <<EOF
    ${CORE_DNS_MARKER}
    hosts {
        ${ip} ${ENDPOINT_HOSTNAME}
        fallthrough
    }
EOF
    )

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == *"$CORE_DNS_MARKER"* ]]; then
            skipping=1
            continue
        fi
        if ((skipping)); then
            if [[ $line =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
                skipping=0
            fi
            continue
        fi
        kept+=("$line")
        if ((inserted == 0)) && [[ $line =~ ^\.:53[[:space:]]*\{[[:space:]]*$ ]]; then
            kept+=("$hosts_block")
            inserted=1
        fi
    done <<<"$corefile"

    ((inserted == 1)) || error "Corefile has no '.:53 {' server block to attach the endpoint host to"
    printf '%s\n' "${kept[@]}"
}

# Rewrites a hosts file so the endpoint has one marker line.
render_hosts_file() {
    local existing=$1
    local ip=$2
    local line
    local rewritten=""

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == *"$CORE_DNS_MARKER"* || $line == *" ${ENDPOINT_HOSTNAME}" || $line == *" ${ENDPOINT_HOSTNAME} "* ]]; then
            continue
        fi
        rewritten+="${line}"$'\n'
    done <<<"$existing"
    printf '%s%s %s %s\n' "$rewritten" "$ip" "$ENDPOINT_HOSTNAME" "$CORE_DNS_MARKER"
}

render_tcp_services_configmap() {
    local size=$1
    local i=0 port
    cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tcp-services
  namespace: ${INGRESS_NAMESPACE}
data:
EOF
    for port in $(ingress_ports "$size"); do
        printf '  "%s": "%s/%s:%s"\n' "$port" "$CLUSTER_NAMESPACE" "$(pod_service_name "$i")" "$SERVICE_PORT"
        i=$((i + 1))
    done
}

render_ingress_container_patch() {
    local size=$1
    local port
    printf '[\n'
    printf '  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--tcp-services-configmap=%s/tcp-services"}' \
        "$INGRESS_NAMESPACE"
    for port in $(ingress_ports "$size"); do
        printf ',\n  {"op":"add","path":"/spec/template/spec/containers/0/ports/-","value":{"name":"as-%s","containerPort":%s,"hostPort":%s,"protocol":"TCP"}}' \
            "$port" "$port" "$port"
    done
    printf '\n]\n'
}

render_probe_service() {
    local node_port=$1
    cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nodeport-probe-${node_port}
  namespace: nodeport-range-probe
spec:
  type: NodePort
  selector:
    app: nodeport-range-probe
  ports:
    - name: probe
      port: 80
      targetPort: 80
      nodePort: ${node_port}
EOF
}

render_cluster_manifest() {
    local image=$1
    local size=$2
    local rf=1

    validate_image_ref "$image"
    validate_cluster_size "$size"
    if ((size >= 2)); then
        rf=2
    fi

    cat <<EOF
apiVersion: asdb.aerospike.com/v1
kind: AerospikeCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${CLUSTER_NAMESPACE}
spec:
  size: ${size}
  image: ${image}
  podSpec:
    multiPodPerHost: true
  validationPolicy:
    # AKO otherwise requires /opt/aerospike on a persistent volume. emptyDir is
    # not one. Setting work-directory still checks that this path is mounted.
    skipWorkDirValidate: true
  aerospikeNetworkPolicy:
    access: pod
    # KO-649: replace configuredIP and the node label with the CR hostname field.
    alternateAccess: configuredIP
  storage:
    filesystemVolumePolicy:
      cascadeDelete: true
      initMethod: deleteFiles
    volumes:
      - name: workdir
        source:
          emptyDir: {}
        aerospike:
          path: /opt/aerospike
      - name: aerospike-config-secret
        source:
          secret:
            secretName: aerospike-secret
        aerospike:
          path: /etc/aerospike/secret
  aerospikeAccessControl:
    users:
      - name: admin
        secretName: auth-secret
        roles:
          - sys-admin
          - user-admin
          - data-admin
          - read-write
  aerospikeConfig:
    service:
      feature-key-file: /etc/aerospike/secret/features.conf
      work-directory: /opt/aerospike
      cgroup-mem-tracking: true
    security: {}
    network:
      service:
        port: ${SERVICE_PORT}
      fabric:
        port: 3001
      heartbeat:
        port: 3002
    namespaces:
      - name: test
        replication-factor: ${rf}
        storage-engine:
          type: memory
          # Server 8.1.2 rejects a memory data-size below 512MiB.
          data-size: 536870912
EOF
}

render_rbac_manifest() {
    cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aerospike-operator-controller-manager
  namespace: ${CLUSTER_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aerospike-cluster-${CLUSTER_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aerospike-cluster
subjects:
  - kind: ServiceAccount
    name: aerospike-operator-controller-manager
    namespace: ${CLUSTER_NAMESPACE}
EOF
}

render_ingress_values() {
    cat <<'EOF'
controller:
  replicaCount: 1
  # 80 and 443 are unused. Enabling hostPort for them deadlocks a rolling
  # update on the one kind node: the new pod cannot bind those ports while
  # the previous controller still holds them. The tcp-services port is added
  # later as hostPort 9000.
  hostPort:
    enabled: false
  admissionWebhooks:
    enabled: false
  service:
    type: NodePort
EOF
}
