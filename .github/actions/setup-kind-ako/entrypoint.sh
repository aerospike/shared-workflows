#!/usr/bin/env bash
# Setup a kind cluster with AKO for L3 discovery tests.
set -euo pipefail

export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR

# shellcheck disable=SC2317
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: command failed with exit code ${exit_code} at line ${line_number}" >&2
    exit "$exit_code"
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

show_help() {
    cat <<'EOF'
Usage: entrypoint.sh <command>

Commands:
  record-inputs           Validate action inputs and store them for later steps
  install-tools           Install pinned kind, helm, and kubectl
  create-cluster          kind create with the pinned NodePort range and extraPortMappings
  assert-nodeport-range   Fail unless the API server is serving 30000-32767
  prepare-node            Untaint the node, label it, and add the CoreDNS entry
  install-ako             Install cert-manager and AKO and wait for CRDs
  deploy-cluster          Apply secrets and an AerospikeCluster
  install-ingress         Install ingress-nginx and the tcp-services ConfigMap
  publish-outputs         Write action outputs

Inputs are environment variables set by action.yaml. Run record-inputs first.
EOF
}

maybe_trace() {
    if [[ ${ENABLE_BASH_TRACE_MODE-} == true ]]; then
        set -x
    fi
}

load_state() {
    local env_file
    env_file="$(state_dir)/env.sh"
    [[ -f $env_file ]] || error "action inputs were not recorded"
    # shellcheck disable=SC1090
    source "$env_file"
    maybe_trace
}

require_cmd() {
    local name=$1
    command -v "$name" >/dev/null 2>&1 || error "$name is not on PATH; install-tools did not run"
}

write_output() {
    local key=$1
    local value=$2
    [[ $value != *$'\n'* ]] || error "output $key contains a newline"
    if [[ -n ${GITHUB_OUTPUT-} ]]; then
        printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
    fi
    printf '%s=%s\n' "$key" "$value"
}

host_os() {
    uname -s | tr '[:upper:]' '[:lower:]'
}

host_arch() {
    case $(uname -m) in
    x86_64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *) error "unsupported architecture $(uname -m)" ;;
    esac
}

download() {
    local url=$1
    local dest=$2
    curl -fsSL "$url" -o "$dest"
}

cmd_record_inputs() {
    local dir env_file
    dir=$(state_dir)
    mkdir -p "$dir"
    env_file="$dir/env.sh"
    : >"$env_file"

    local kind_cluster_name=${KIND_CLUSTER_NAME:-kind-ako}
    local kind_node_image=${KIND_NODE_IMAGE:-kindest/node:v1.35.0}
    local kind_version=${KIND_VERSION:-v0.33.0}
    local kubectl_version=${KUBECTL_VERSION:-v1.35.0}
    local helm_version=${HELM_VERSION:-v3.18.4}
    local client_ports=${CLIENT_PORTS:-30000-32767}
    local ingress_port_base=${INGRESS_PORT_BASE:-9000}
    local cluster_size=${CLUSTER_SIZE:-1}
    local cluster_name=${CLUSTER_NAME:-aerocluster}
    local cluster_namespace=${CLUSTER_NAMESPACE:-aerospike}
    local ako_namespace=${AKO_NAMESPACE:-ako}
    local ingress_namespace=${INGRESS_NAMESPACE:-ingress-nginx}
    local endpoint_hostname=${ENDPOINT_HOSTNAME:-as-endpoint.test}
    local server_image=${SERVER_IMAGE:-aerospike/aerospike-server-enterprise:8.1.2.5}
    local ako_chart_version=${AKO_CHART_VERSION:-4.5.0}
    local ako_helm_repo=${AKO_HELM_REPO:-https://aerospike.github.io/aerospike-kubernetes-enterprise}
    local cert_manager_chart_version=${CERT_MANAGER_CHART_VERSION:-v1.17.0}
    local cert_manager_helm_repo=${CERT_MANAGER_HELM_REPO:-https://charts.jetstack.io}
    local ingress_nginx_chart_version=${INGRESS_NGINX_CHART_VERSION:-4.12.1}
    local ingress_nginx_helm_repo=${INGRESS_NGINX_HELM_REPO:-https://kubernetes.github.io/ingress-nginx}
    local startup_timeout=${STARTUP_TIMEOUT:-600}
    local trace=${ENABLE_BASH_TRACE_MODE:-false}
    local admin_password=${ADMIN_PASSWORD-}

    validate_dns_label "$kind_cluster_name" "kind-cluster-name"
    validate_dns_label "$cluster_name" "cluster-name"
    validate_dns_label "$cluster_namespace" "cluster-namespace"
    validate_dns_label "$ako_namespace" "ako-namespace"
    validate_dns_label "$ingress_namespace" "ingress-namespace"
    validate_hostname "$endpoint_hostname" "endpoint-hostname"
    validate_image_ref "$kind_node_image" "kind-node-image"
    validate_image_ref "$server_image" "server-image"
    validate_semver_tag "$kind_version" "kind-version"
    validate_semver_tag "$kubectl_version" "kubectl-version"
    validate_semver_tag "$helm_version" "helm-version"
    validate_semver_tag "$ako_chart_version" "ako-chart-version"
    validate_semver_tag "$cert_manager_chart_version" "cert-manager-chart-version"
    validate_semver_tag "$ingress_nginx_chart_version" "ingress-nginx-chart-version"
    validate_https_url "$ako_helm_repo" "ako-helm-repo"
    validate_https_url "$cert_manager_helm_repo" "cert-manager-helm-repo"
    validate_https_url "$ingress_nginx_helm_repo" "ingress-nginx-helm-repo"
    validate_positive_int "$startup_timeout" "startup-timeout"
    ((startup_timeout <= 3600)) || error "startup-timeout must be <= 3600 (got: $startup_timeout)"
    [[ $trace == true || $trace == false ]] || error "enable-bash-trace-mode must be true or false (got: '$trace')"

    # Expand once so a bad spec fails before kind create. Also rejects ingress
    # ports that collide with the pinned NodePort range.
    expand_port_spec "$client_ports" >/dev/null
    ingress_ports "$ingress_port_base" "$cluster_size" >/dev/null

    if [[ -n ${FEATURES_FILE-} ]]; then
        [[ -f $FEATURES_FILE ]] || error "features-file does not exist: $FEATURES_FILE"
        cp "$FEATURES_FILE" "$dir/features.conf"
    elif [[ -n ${FEATURES_CONTENT-} ]]; then
        printf '%s' "$FEATURES_CONTENT" >"$dir/features.conf"
    else
        error "features-file or features-content is required"
    fi
    [[ -s $dir/features.conf ]] || error "feature key file is empty"

    if [[ -z $admin_password ]]; then
        admin_password=$(openssl rand -hex 16)
    fi
    [[ $admin_password =~ ^[A-Za-z0-9]{8,128}$ ]] ||
        error "admin-password must be 8-128 letters or digits"
    printf '%s' "$admin_password" >"$dir/admin-password"
    chmod 600 "$dir/admin-password"
    echo "::add-mask::${admin_password}"

    {
        printf 'KIND_CLUSTER_NAME=%q\n' "$kind_cluster_name"
        printf 'KIND_NODE_IMAGE=%q\n' "$kind_node_image"
        printf 'KIND_VERSION=%q\n' "$kind_version"
        printf 'KUBECTL_VERSION=%q\n' "$kubectl_version"
        printf 'HELM_VERSION=%q\n' "$helm_version"
        printf 'CLIENT_PORTS=%q\n' "$client_ports"
        printf 'INGRESS_PORT_BASE=%q\n' "$ingress_port_base"
        printf 'CLUSTER_SIZE=%q\n' "$cluster_size"
        printf 'CLUSTER_NAME=%q\n' "$cluster_name"
        printf 'CLUSTER_NAMESPACE=%q\n' "$cluster_namespace"
        printf 'AKO_NAMESPACE=%q\n' "$ako_namespace"
        printf 'INGRESS_NAMESPACE=%q\n' "$ingress_namespace"
        printf 'ENDPOINT_HOSTNAME=%q\n' "$endpoint_hostname"
        printf 'SERVER_IMAGE=%q\n' "$server_image"
        printf 'AKO_CHART_VERSION=%q\n' "$ako_chart_version"
        printf 'AKO_HELM_REPO=%q\n' "$ako_helm_repo"
        printf 'CERT_MANAGER_CHART_VERSION=%q\n' "$cert_manager_chart_version"
        printf 'CERT_MANAGER_HELM_REPO=%q\n' "$cert_manager_helm_repo"
        printf 'INGRESS_NGINX_CHART_VERSION=%q\n' "$ingress_nginx_chart_version"
        printf 'INGRESS_NGINX_HELM_REPO=%q\n' "$ingress_nginx_helm_repo"
        printf 'STARTUP_TIMEOUT=%q\n' "$startup_timeout"
        printf 'ENABLE_BASH_TRACE_MODE=%q\n' "$trace"
        printf 'FEATURES_CONF=%q\n' "$dir/features.conf"
        printf 'ADMIN_PASSWORD_FILE=%q\n' "$dir/admin-password"
    } >"$env_file"
    echo "Recorded setup-kind-ako inputs in $env_file"
}

cmd_install_tools() {
    load_state
    local os arch bindir
    os=$(host_os)
    arch=$(host_arch)
    case $os in
    linux | darwin) ;;
    *) error "unsupported OS $os" ;;
    esac
    bindir="$(state_dir)/bin"
    mkdir -p "$bindir"

    echo "Installing kind ${KIND_VERSION}"
    download "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${os}-${arch}" "$bindir/kind"
    echo "Installing kubectl ${KUBECTL_VERSION}"
    download "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl" "$bindir/kubectl"
    echo "Installing helm ${HELM_VERSION}"
    local helm_tar
    helm_tar="$(state_dir)/helm.tgz"
    download "https://get.helm.sh/helm-${HELM_VERSION}-${os}-${arch}.tar.gz" "$helm_tar"
    tar -xzf "$helm_tar" -C "$(state_dir)"
    mv "$(state_dir)/${os}-${arch}/helm" "$bindir/helm"
    chmod 755 "$bindir/kind" "$bindir/kubectl" "$bindir/helm"

    if [[ -n ${GITHUB_PATH-} ]]; then
        printf '%s\n' "$bindir" >>"$GITHUB_PATH"
    fi
    export PATH="${bindir}:${PATH}"
    kind version
    kubectl version --client
    helm version --short
}

cmd_create_cluster() {
    load_state
    require_cmd kind
    require_cmd kubectl
    local config
    config="$(state_dir)/kind-config.yaml"
    render_kind_config "$CLIENT_PORTS" "$INGRESS_PORT_BASE" "$CLUSTER_SIZE" >"$config"
    echo "Creating kind cluster ${KIND_CLUSTER_NAME} from ${config}"
    kind create cluster --name "$KIND_CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --config "$config" --wait 180s
    kubectl wait --for=condition=Ready nodes --all --timeout=180s
}

collect_apiserver_cmdline() {
    python3 - <<'PY'
import json, subprocess, sys
raw = subprocess.check_output(["kubectl", "-n", "kube-system", "get", "pods", "-o", "json"])
pods = json.loads(raw)["items"]
lines = []
for pod in pods:
    for container in pod.get("spec", {}).get("containers", []):
        command = container.get("command") or []
        args = container.get("args") or []
        blob = " ".join(command + args + [container.get("name", "")])
        if "kube-apiserver" not in blob:
            continue
        lines.extend(command)
        lines.extend(args)
if not lines:
    sys.exit("no kube-apiserver container found")
print("\n".join(lines))
PY
}

node_internal_ip() {
    python3 - <<'PY'
import json, subprocess, sys
raw = subprocess.check_output(["kubectl", "get", "nodes", "-o", "json"])
nodes = json.loads(raw)["items"]
if not nodes:
    sys.exit("kind cluster has no nodes")
for addr in nodes[0].get("status", {}).get("addresses", []):
    if addr.get("type") == "InternalIP":
        print(addr["address"])
        break
else:
    sys.exit("kind node has no InternalIP")
PY
}

service_node_ports_csv() {
    local ns=$1
    local service_port=$2
    shift 2
    python3 - "$ns" "$service_port" "$@" <<'PY'
import json, subprocess, sys
ns, service_port, *names = sys.argv[1:]
service_port = int(service_port)
raw = subprocess.check_output(["kubectl", "-n", ns, "get", "svc", "-o", "json"])
items = {item["metadata"]["name"]: item for item in json.loads(raw)["items"]}
found = []
for name in names:
    svc = items.get(name)
    if svc is None:
        sys.exit(f"service {name} not found in namespace {ns}")
    node_port = None
    for port in svc["spec"].get("ports", []):
        if port.get("port") == service_port:
            node_port = port.get("nodePort")
    if not node_port:
        sys.exit(f"service {name} has no nodePort for service port {service_port}")
    found.append(str(node_port))
print(",".join(found))
PY
}

probe_nodeport() {
    local port=$1
    local expect manifest errfile
    expect=$(nodeport_probe_expectation "$port")
    manifest="$(state_dir)/probe-${port}.yaml"
    errfile="$(state_dir)/probe-${port}.err"
    render_probe_service nodeport-range-probe "$port" >"$manifest"
    if kubectl apply -f "$manifest" >"$errfile" 2>&1; then
        kubectl -n nodeport-range-probe delete "svc/nodeport-probe-${port}" --wait=true >/dev/null
        if [[ $expect == reject ]]; then
            error "API server accepted nodePort ${port}, which is outside $(pinned_nodeport_range)"
        fi
    else
        if [[ $expect == accept ]]; then
            error "API server rejected nodePort ${port}, which is inside $(pinned_nodeport_range). $(<"$errfile")"
        fi
        if ! grep -q -F "$(pinned_nodeport_range)" "$errfile"; then
            error "nodePort ${port} was rejected, but the API server did not report range $(pinned_nodeport_range). $(<"$errfile")"
        fi
    fi
}

cmd_assert_nodeport_range() {
    load_state
    require_cmd kubectl
    local text start end
    text=$(collect_apiserver_cmdline)
    echo "API server command line:" >&2
    printf '%s\n' "$text" >&2
    assert_pinned_nodeport_flag "$text"

    kubectl create namespace nodeport-range-probe --dry-run=client -o yaml | kubectl apply -f -
    trap 'kubectl delete namespace nodeport-range-probe --wait=false --ignore-not-found >/dev/null 2>&1 || true' EXIT
    start=$(pinned_nodeport_start)
    end=$(pinned_nodeport_end)
    probe_nodeport $((start - 1))
    probe_nodeport "$start"
    probe_nodeport "$end"
    probe_nodeport $((end + 1))
    echo "API server NodePort range is $(pinned_nodeport_range)"
}

apply_corefile() {
    local corefile_path=$1
    python3 - "$corefile_path" <<'PY'
import json, subprocess, sys
corefile = open(sys.argv[1]).read()
raw = subprocess.check_output(["kubectl", "-n", "kube-system", "get", "cm", "coredns", "-o", "json"])
obj = json.loads(raw)
obj.setdefault("data", {})["Corefile"] = corefile
meta = obj["metadata"]
for key in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
    meta.pop(key, None)
obj.pop("status", None)
subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(obj).encode(), check=True)
PY
}

install_runner_hosts() {
    local hostname=$1
    local updated tmp
    updated=$(render_hosts_file "$(cat /etc/hosts)" "127.0.0.1" "$hostname")
    tmp="$(state_dir)/hosts"
    printf '%s\n' "$updated" >"$tmp"
    if [[ -w /etc/hosts ]]; then
        cp "$tmp" /etc/hosts
    else
        sudo cp "$tmp" /etc/hosts
    fi
}

cmd_prepare_node() {
    load_state
    require_cmd kubectl
    local ip corefile corefile_path label
    kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || true
    kubectl taint nodes --all node-role.kubernetes.io/master:NoSchedule- || true
    label=$(configured_alternate_access_label)
    kubectl label nodes --all "${label}=${ENDPOINT_HOSTNAME}" --overwrite

    ip=$(node_internal_ip)
    corefile=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')
    [[ -n $corefile ]] || error "kube-system/coredns ConfigMap has no Corefile"
    corefile_path="$(state_dir)/Corefile"
    render_corefile_with_endpoint "$corefile" "$ip" "$ENDPOINT_HOSTNAME" >"$corefile_path"
    apply_corefile "$corefile_path"
    kubectl -n kube-system rollout restart deploy/coredns
    kubectl -n kube-system rollout status deploy/coredns --timeout=180s
    install_runner_hosts "$ENDPOINT_HOSTNAME"
    echo "CoreDNS resolves ${ENDPOINT_HOSTNAME} to ${ip}; the runner resolves it to 127.0.0.1"
}

cmd_install_ako() {
    load_state
    require_cmd helm
    require_cmd kubectl
    helm repo add jetstack "$CERT_MANAGER_HELM_REPO" --force-update
    helm repo add aerospike "$AKO_HELM_REPO" --force-update
    helm repo update
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --version "$CERT_MANAGER_CHART_VERSION" \
        --set crds.enabled=true \
        --wait --timeout 10m
    kubectl create namespace "$CLUSTER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install aerospike-kubernetes-operator aerospike/aerospike-kubernetes-operator \
        --namespace "$AKO_NAMESPACE" --create-namespace \
        --version "$AKO_CHART_VERSION" \
        --set "watchNamespaces=${CLUSTER_NAMESPACE}" \
        --wait --timeout 10m
    kubectl wait --for=condition=Established crd/aerospikeclusters.asdb.aerospike.com --timeout=180s
    kubectl get clusterrole aerospike-cluster >/dev/null
    render_rbac_manifest "$CLUSTER_NAMESPACE" | kubectl apply -f -
}

dump_cluster_debug() {
    echo "AKO manager log:" >&2
    kubectl -n "$AKO_NAMESPACE" logs deploy/aerospike-kubernetes-operator -c manager --tail=80 >&2 || true
    echo "Aerospike namespace:" >&2
    kubectl -n "$CLUSTER_NAMESPACE" get pods,svc,aerospikecluster -o wide >&2 || true
    kubectl -n "$CLUSTER_NAMESPACE" describe "aerospikecluster/${CLUSTER_NAME}" >&2 || true
}

cmd_deploy_cluster() {
    load_state
    require_cmd kubectl
    local password
    password=$(<"$ADMIN_PASSWORD_FILE")
    echo "::add-mask::${password}"
    kubectl -n "$CLUSTER_NAMESPACE" create secret generic aerospike-secret \
        --from-file="features.conf=${FEATURES_CONF}" \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "$CLUSTER_NAMESPACE" create secret generic auth-secret \
        --from-literal="password=${password}" \
        --dry-run=client -o yaml | kubectl apply -f -
    render_cluster_manifest "$CLUSTER_NAMESPACE" "$CLUSTER_NAME" "$SERVER_IMAGE" "$CLUSTER_SIZE" |
        kubectl apply -f -
    if ! kubectl -n "$CLUSTER_NAMESPACE" wait "aerospikecluster/${CLUSTER_NAME}" \
        --for=jsonpath='{.status.phase}'=Completed \
        --timeout="${STARTUP_TIMEOUT}s"; then
        dump_cluster_debug
        error "AerospikeCluster ${CLUSTER_NAME} did not reach Completed within ${STARTUP_TIMEOUT}s"
    fi
}

expected_service_names() {
    local i
    for ((i = 0; i < CLUSTER_SIZE; i++)); do
        pod_service_name "$CLUSTER_NAME" "$i"
    done
}

cmd_install_ingress() {
    load_state
    require_cmd helm
    require_cmd kubectl
    local svc names=() container values patch
    while IFS= read -r svc; do
        [[ -n $svc ]] || continue
        kubectl -n "$CLUSTER_NAMESPACE" get "svc/${svc}" >/dev/null
        names+=("$svc")
    done <<<"$(expected_service_names)"
    ((${#names[@]} > 0)) || error "no Aerospike services to publish through ingress"

    kubectl create namespace "$INGRESS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    render_tcp_services_configmap "$INGRESS_NAMESPACE" "$INGRESS_PORT_BASE" \
        "$CLUSTER_NAMESPACE" "$CLUSTER_NAME" "$CLUSTER_SIZE" 3000 |
        kubectl apply -f -
    values="$(state_dir)/ingress-values.yaml"
    render_ingress_values >"$values"
    helm repo add ingress-nginx "$INGRESS_NGINX_HELM_REPO" --force-update
    helm repo update
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace "$INGRESS_NAMESPACE" \
        --version "$INGRESS_NGINX_CHART_VERSION" \
        -f "$values" \
        --wait --timeout 10m
    container=$(kubectl -n "$INGRESS_NAMESPACE" get deploy ingress-nginx-controller \
        -o jsonpath='{.spec.template.spec.containers[0].name}')
    [[ $container == controller ]] ||
        error "ingress-nginx container[0] is '${container}', want controller"
    patch="$(state_dir)/ingress-patch.json"
    render_ingress_container_patch "$INGRESS_NAMESPACE" "$INGRESS_PORT_BASE" "$CLUSTER_SIZE" >"$patch"
    kubectl -n "$INGRESS_NAMESPACE" patch deploy ingress-nginx-controller --type=json --patch-file="$patch"
    kubectl -n "$INGRESS_NAMESPACE" rollout status deploy/ingress-nginx-controller --timeout=180s
}

join_csv() {
    local first=1 item
    for item in "$@"; do
        if ((first)); then
            printf '%s' "$item"
            first=0
        else
            printf ',%s' "$item"
        fi
    done
    printf '\n'
}

cmd_publish_outputs() {
    load_state
    require_cmd kubectl
    local password ingress_csv node_csv names=() svc port node_port
    local -a ingress=()
    local -a endpoints=()
    local -a service_endpoints=()
    local -a node_ports=()
    password=$(<"$ADMIN_PASSWORD_FILE")
    echo "::add-mask::${password}"
    while IFS= read -r port; do
        [[ -n $port ]] || continue
        ingress+=("$port")
        endpoints+=("${ENDPOINT_HOSTNAME}:${port}")
    done <<<"$(ingress_ports "$INGRESS_PORT_BASE" "$CLUSTER_SIZE")"
    ingress_csv=$(join_csv "${ingress[@]}")
    while IFS= read -r svc; do
        [[ -n $svc ]] || continue
        names+=("$svc")
    done <<<"$(expected_service_names)"
    node_csv=$(service_node_ports_csv "$CLUSTER_NAMESPACE" 3000 "${names[@]}")
    IFS=',' read -ra node_ports <<<"$node_csv"
    for node_port in "${node_ports[@]}"; do
        service_endpoints+=("${ENDPOINT_HOSTNAME}:${node_port}")
    done

    write_output admin-password "$password"
    write_output cluster-name "$CLUSTER_NAME"
    write_output cluster-namespace "$CLUSTER_NAMESPACE"
    write_output endpoint-address "127.0.0.1"
    write_output endpoint-hostname "$ENDPOINT_HOSTNAME"
    write_output ingress-endpoints "$(join_csv "${endpoints[@]}")"
    write_output ingress-ports "$ingress_csv"
    write_output kind-cluster-name "$KIND_CLUSTER_NAME"
    write_output kubeconfig "${KUBECONFIG:-${HOME}/.kube/config}"
    write_output node-port-range "$(pinned_nodeport_range)"
    write_output service-endpoints "$(join_csv "${service_endpoints[@]}")"
    write_output service-node-ports "$node_csv"
}

main() {
    local cmd=${1-}
    case $cmd in
    record-inputs) cmd_record_inputs ;;
    install-tools) cmd_install_tools ;;
    create-cluster) cmd_create_cluster ;;
    assert-nodeport-range) cmd_assert_nodeport_range ;;
    prepare-node) cmd_prepare_node ;;
    install-ako) cmd_install_ako ;;
    deploy-cluster) cmd_deploy_cluster ;;
    install-ingress) cmd_install_ingress ;;
    publish-outputs) cmd_publish_outputs ;;
    -h | --help | help) show_help ;;
    "")
        show_help >&2
        exit 1
        ;;
    *)
        error "unknown command '$cmd'"
        ;;
    esac
}

main "$@"
