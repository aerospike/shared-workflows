#!/usr/bin/env bash
# Pure helpers for setup-kind-ako. No kubectl, helm, or kind side effects.

error() {
    local reason="${1-}"
    if [[ -n $reason ]]; then
        echo "Error: $reason" >&2
    else
        echo "Error" >&2
    fi
    exit 1
}

# K-7 is meaningless unless this is the Kubernetes default. Callers cannot
# override it. assert-nodeport-range fails the job when the API server
# serves anything else.
pinned_nodeport_range() {
    printf '30000-32767\n'
}

pinned_nodeport_start() {
    local range
    range=$(pinned_nodeport_range)
    printf '%s\n' "${range%%-*}"
}

pinned_nodeport_end() {
    local range
    range=$(pinned_nodeport_range)
    printf '%s\n' "${range##*-}"
}

state_dir() {
    printf '%s\n' "${SETUP_KIND_AKO_STATE:-${RUNNER_TEMP:-/tmp}/setup-kind-ako}"
}

validate_port() {
    local value=$1
    local label=$2
    [[ $value =~ ^[1-9][0-9]*$ ]] || error "$label must be a positive integer (got: '$value')"
    ((value <= 65535)) || error "$label must be <= 65535 (got: $value)"
}

validate_positive_int() {
    local value=$1
    local label=$2
    [[ $value =~ ^[1-9][0-9]*$ ]] || error "$label must be a positive integer (got: '$value')"
}

validate_dns_label() {
    local value=$1
    local label=$2
    [[ $value =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] ||
        error "$label is not a DNS label (got: '$value')"
}

validate_hostname() {
    local value=$1
    local label=$2
    [[ $value =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] ||
        error "$label is not a valid hostname (got: '$value')"
    ((${#value} <= 63)) || error "$label must be <= 63 characters so it can be a node label (got: '$value')"
}

validate_semver_tag() {
    local value=$1
    local label=$2
    [[ $value =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        error "$label must look like 1.2.3 or v1.2.3 (got: '$value')"
}

validate_https_url() {
    local value=$1
    local label=$2
    [[ $value =~ ^https://[A-Za-z0-9._/-]+$ ]] ||
        error "$label must be an https URL without query or userinfo (got: '$value')"
}

validate_image_ref() {
    local value=$1
    local label=$2
    [[ $value =~ ^[A-Za-z0-9._:/@-]+$ ]] ||
        error "$label contains characters that are not valid in an image reference (got: '$value')"
}

# Prints one port per line. Spec is comma-separated N or N-M tokens.
expand_port_spec() {
    local spec=${1-}
    local token start end port span
    local -a tokens

    [[ -n $spec ]] || error "port spec is empty"
    IFS=',' read -ra tokens <<<"$spec"
    for token in "${tokens[@]}"; do
        token="${token//[[:space:]]/}"
        [[ -n $token ]] || error "port spec contains an empty entry"
        if [[ $token =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            validate_port "$start" "port range start"
            validate_port "$end" "port range end"
            ((10#$start <= 10#$end)) || error "port range start $start is greater than end $end"
            span=$((10#$end - 10#$start))
            ((span <= 10000)) || error "port range $token is larger than 10000 ports"
            for ((port = 10#$start; port <= 10#$end; port++)); do
                printf '%s\n' "$port"
            done
        elif [[ $token =~ ^[0-9]+$ ]]; then
            validate_port "$token" "port"
            printf '%s\n' "$((10#$token))"
        else
            error "invalid port token '$token' (want N or N-M)"
        fi
    done
}

# Prints deduplicated ports, first-seen order, one per line.
# Arguments are newline-separated port streams passed as a single string.
dedupe_ports() {
    local port
    local -A seen
    while IFS= read -r port; do
        [[ -n $port ]] || continue
        [[ -v seen[$port] ]] && continue
        seen[$port]=1
        printf '%s\n' "$port"
    done
}

ingress_ports() {
    local base=$1
    local size=$2
    local i port
    validate_port "$base" "ingress-port-base"
    validate_positive_int "$size" "cluster-size"
    ((size <= 8)) || error "cluster-size must be <= 8 (got: $size)"
    local start end
    start=$(pinned_nodeport_start)
    end=$(pinned_nodeport_end)
    for ((i = 0; i < size; i++)); do
        port=$((base + i))
        validate_port "$port" "ingress port"
        if ((port >= start && port <= end)); then
            error "ingress port $port falls inside the pinned NodePort range ${start}-${end}; choose a different ingress-port-base"
        fi
        printf '%s\n' "$port"
    done
}

pod_service_name() {
    local cluster_name=$1
    local index=$2
    printf '%s-0-%s\n' "$cluster_name" "$index"
}

configured_alternate_access_label() {
    printf 'aerospike.com/configured-alternate-access-address\n'
}

nodeport_probe_expectation() {
    local port=$1
    local start end
    validate_port "$port" "nodePort"
    start=$(pinned_nodeport_start)
    end=$(pinned_nodeport_end)
    if ((port < start || port > end)); then
        printf 'reject\n'
    else
        printf 'accept\n'
    fi
}

# Prints the service-node-port-range values found in an API server command line.
extract_nodeport_ranges() {
    local text=$1
    local line
    while IFS= read -r line; do
        if [[ $line =~ --service-node-port-range=([0-9]+-[0-9]+) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        elif [[ $line =~ --service-node-port-range[[:space:]]+([0-9]+-[0-9]+) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done <<<"$text"
}

assert_pinned_nodeport_flag() {
    local text=$1
    local want found count
    want=$(pinned_nodeport_range)
    found=$(extract_nodeport_ranges "$text")
    if [[ -z $found ]]; then
        error "API server command line does not set --service-node-port-range. K-7 requires an explicit pin of ${want}."
    fi
    count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
    if [[ $count != 1 || $found != "$want" ]]; then
        error "API server NodePort range is '${found//$'\n'/,}', want exactly ${want}. Do not widen service-node-port-range; K-7 depends on KEP-3668's default static band."
    fi
}

render_kind_config() {
    local client_ports_spec=$1
    local ingress_base=$2
    local cluster_size=$3
    local port client_blob ingress_blob combined
    local -a ports=()

    client_blob=$(expand_port_spec "$client_ports_spec")
    ingress_blob=$(ingress_ports "$ingress_base" "$cluster_size")
    combined=$(printf '%s\n%s\n' "$client_blob" "$ingress_blob" | dedupe_ports)
    while IFS= read -r port; do
        [[ -n $port ]] || continue
        ports+=("$port")
    done <<<"$combined"
    ((${#ports[@]} > 0)) || error "no ports to publish"

    # kind v0.33 emits kubeadm v1beta3, with extraArgs as a map, for every
    # Kubernetes version below 1.36. A v1beta4 list does not match that
    # document, so kubeadm never receives the flag. Keep this patch on
    # v1beta3 while KIND_NODE_IMAGE stays below v1.36.
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
            service-node-port-range: "$(pinned_nodeport_range)"
    extraPortMappings:
EOF
    for port in "${ports[@]}"; do
        cat <<EOF
      - containerPort: ${port}
        hostPort: ${port}
        listenAddress: "127.0.0.1"
        protocol: TCP
EOF
    done
}

CORE_DNS_MARKER="# setup-kind-ako endpoint"

render_corefile_with_endpoint() {
    local corefile=$1
    local ip=$2
    local hostname=$3
    local hosts_block line
    local -a kept=()
    local skipping=0
    local inserted=0

    [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || error "CoreDNS address is not an IP (got: '$ip')"
    validate_hostname "$hostname" "endpoint-hostname"

    hosts_block=$(
        cat <<EOF
    ${CORE_DNS_MARKER}
    hosts {
        ${ip} ${hostname}
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

runner_hosts_line() {
    local ip=$1
    local hostname=$2
    validate_hostname "$hostname" "endpoint-hostname"
    [[ $ip =~ ^[0-9.]+$ ]] || error "runner hosts address is not an IPv4 address (got: '$ip')"
    printf '%s %s %s\n' "$ip" "$hostname" "$CORE_DNS_MARKER"
}

# Rewrites a hosts file so the endpoint has one marker line.
render_hosts_file() {
    local existing=$1
    local ip=$2
    local hostname=$3
    local line
    local rewritten=""
    local new_line
    new_line=$(runner_hosts_line "$ip" "$hostname")

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == *"$CORE_DNS_MARKER"* || $line == *" ${hostname}" || $line == *" ${hostname} "* ]]; then
            continue
        fi
        rewritten+="${line}"$'\n'
    done <<<"$existing"
    printf '%s%s\n' "$rewritten" "$new_line"
}

render_tcp_services_configmap() {
    local namespace=$1
    local ingress_base=$2
    local cluster_namespace=$3
    local cluster_name=$4
    local cluster_size=$5
    local service_port=$6
    local i port svc

    validate_dns_label "$namespace" "ingress namespace"
    validate_dns_label "$cluster_namespace" "cluster namespace"
    validate_dns_label "$cluster_name" "cluster name"
    validate_port "$service_port" "service port"

    local ports_blob
    ports_blob=$(ingress_ports "$ingress_base" "$cluster_size")
    cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tcp-services
  namespace: ${namespace}
data:
EOF
    i=0
    while IFS= read -r port; do
        [[ -n $port ]] || continue
        svc=$(pod_service_name "$cluster_name" "$i")
        printf '  "%s": "%s/%s:%s"\n' "$port" "$cluster_namespace" "$svc" "$service_port"
        i=$((i + 1))
    done <<<"$ports_blob"
}

render_ingress_container_patch() {
    local namespace=$1
    local ingress_base=$2
    local cluster_size=$3
    local port ports_blob count=0

    validate_dns_label "$namespace" "ingress namespace"
    ports_blob=$(ingress_ports "$ingress_base" "$cluster_size")
    printf '[\n'
    printf '  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--tcp-services-configmap=%s/tcp-services"}' \
        "$namespace"
    while IFS= read -r port; do
        [[ -n $port ]] || continue
        printf ',\n  {"op":"add","path":"/spec/template/spec/containers/0/ports/-","value":{"name":"as-%s","containerPort":%s,"hostPort":%s,"protocol":"TCP"}}' \
            "$port" "$port" "$port"
        count=$((count + 1))
    done <<<"$ports_blob"
    ((count > 0)) || error "ingress patch has no ports"
    printf '\n]\n'
}

render_probe_service() {
    local namespace=$1
    local node_port=$2
    validate_dns_label "$namespace" "probe namespace"
    validate_port "$node_port" "nodePort"
    cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nodeport-probe-${node_port}
  namespace: ${namespace}
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
    local namespace=$1
    local cluster_name=$2
    local image=$3
    local size=$4
    local rf

    validate_dns_label "$namespace" "cluster namespace"
    validate_dns_label "$cluster_name" "cluster name"
    validate_image_ref "$image" "server-image"
    validate_positive_int "$size" "cluster-size"
    ((size <= 8)) || error "cluster-size must be <= 8 (got: $size)"
    if ((size >= 2)); then
        rf=2
    else
        rf=1
    fi

    cat <<EOF
apiVersion: asdb.aerospike.com/v1
kind: AerospikeCluster
metadata:
  name: ${cluster_name}
  namespace: ${namespace}
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
        port: 3000
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
    local namespace=$1
    validate_dns_label "$namespace" "cluster namespace"
    cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aerospike-operator-controller-manager
  namespace: ${namespace}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aerospike-cluster-${namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aerospike-cluster
subjects:
  - kind: ServiceAccount
    name: aerospike-operator-controller-manager
    namespace: ${namespace}
EOF
}

render_ingress_values() {
    cat <<'EOF'
controller:
  replicaCount: 1
  hostPort:
    enabled: true
  admissionWebhooks:
    enabled: false
  service:
    type: NodePort
EOF
}
