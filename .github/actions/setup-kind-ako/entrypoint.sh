#!/usr/bin/env bash
# Setup a kind cluster with AKO for L3 discovery tests.
# Usage: entrypoint.sh prepare | setup
set -euo pipefail

trap 'handle_error ${LINENO}' ERR

# shellcheck disable=SC2317
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: command failed with exit code ${exit_code} at line ${line_number}" >&2
    exit "$exit_code"
}

TEMPLATES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/templates"
WORK_DIR="${RUNNER_TEMP:-/tmp}/setup-kind-ako"

# The files in templates/ hardcode these names and ports; change both together.
CLUSTER_NAME="aerocluster"
CLUSTER_NAMESPACE="aerospike"
SERVICE_PORT=3000
INGRESS_PORT_BASE=9000
ENDPOINT_HOSTNAME="as-endpoint.test"
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

error() {
    echo "Error: ${1-}" >&2
    exit 1
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

cmd_prepare() {
    local password=${ADMIN_PASSWORD-}
    [[ -n ${FEATURES_CONTENT-} ]] || error "features-content is required"
    [[ $CLUSTER_SIZE =~ ^[1-8]$ ]] || error "cluster-size must be 1-8 (got: '$CLUSTER_SIZE')"
    [[ $SERVER_IMAGE =~ ^[A-Za-z0-9._:/-]+:[A-Za-z0-9._-]+$ ]] ||
        error "server-image must be repository:tag (got: '$SERVER_IMAGE')"
    if [[ -z $password ]]; then
        password=$(openssl rand -hex 16)
    fi
    [[ $password =~ ^[A-Za-z0-9]{8,128}$ ]] || error "admin-password must be 8-128 letters or digits"
    echo "::add-mask::${password}"
    write_output admin-password "$password"
}

prepare_node() {
    local ip corefile
    kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || true
    kubectl taint nodes --all node-role.kubernetes.io/master:NoSchedule- || true
    # ENDPOINT_HOSTNAME is a DNS name. This label is an IP field; AKO 4.5.0
    # copies it through without validating. KO-649 adds a CR hostname field,
    # and a later AKO release will reject a DNS name here. When bumping
    # AKO_CHART_VERSION to a release that includes KO-649, stop labeling the
    # node and set that field in templates/aerospike-cluster-values.yaml. Label values
    # are also limited to 63 characters, so this cannot hold a real PrivateLink name.
    kubectl label nodes --all "${ALTERNATE_ACCESS_LABEL}=${ENDPOINT_HOSTNAME}" --overwrite

    ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    corefile=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' |
        awk -v entry="${ip} ${ENDPOINT_HOSTNAME}" \
            '{ print } /^\.:53 \{/ { print "    hosts {\n        " entry "\n        fallthrough\n    }" }')
    [[ $corefile == *"${ip} ${ENDPOINT_HOSTNAME}"* ]] || error "Corefile has no '.:53 {' server block"
    printf '%s\n' "$corefile" >"$WORK_DIR/Corefile"
    kubectl -n kube-system create configmap coredns --from-file="Corefile=$WORK_DIR/Corefile" \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n kube-system rollout restart deploy/coredns
    kubectl -n kube-system rollout status deploy/coredns --timeout=180s

    echo "${ip} ${ENDPOINT_HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null
    echo "CoreDNS and the runner resolve ${ENDPOINT_HOSTNAME} to ${ip}"
}

install_ako() {
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
    kubectl apply -f "$TEMPLATES/rbac.yaml"
}

render_cluster_manifest() {
    local rf=1
    if ((CLUSTER_SIZE >= 2)); then
        rf=2
    fi
    helm template "$CLUSTER_NAME" aerospike/aerospike-cluster \
        --namespace "$CLUSTER_NAMESPACE" \
        --version "$AKO_CHART_VERSION" \
        -f "$TEMPLATES/aerospike-cluster-values.yaml" \
        --set "replicas=${CLUSTER_SIZE}" \
        --set "image.repository=${SERVER_IMAGE%:*}" \
        --set-string "image.tag=${SERVER_IMAGE##*:}" \
        --set "aerospikeConfig.namespaces[0].replication-factor=${rf}" \
        >"$WORK_DIR/aerospike-cluster.yaml"
}

dump_cluster_debug() {
    echo "AKO manager log:" >&2
    kubectl -n "$AKO_NAMESPACE" logs deploy/aerospike-kubernetes-operator -c manager --tail=80 >&2 || true
    echo "Aerospike namespace:" >&2
    kubectl -n "$CLUSTER_NAMESPACE" get pods,svc,aerospikecluster -o wide >&2 || true
    kubectl -n "$CLUSTER_NAMESPACE" describe "aerospikecluster/${CLUSTER_NAME}" >&2 || true
}

# helm --wait returns before the operator's webhook accepts connections.
wait_for_webhook() {
    local i
    for ((i = 0; i < 60; i++)); do
        if kubectl apply --dry-run=server -f "$WORK_DIR/aerospike-cluster.yaml" >"$WORK_DIR/webhook.err" 2>&1; then
            return 0
        fi
        sleep 3
    done
    error "AKO webhook did not accept the AerospikeCluster within 180s: $(<"$WORK_DIR/webhook.err")"
}

deploy_cluster() {
    printf '%s' "$FEATURES_CONTENT" >"$WORK_DIR/features.conf"
    kubectl -n "$CLUSTER_NAMESPACE" create secret generic aerospike-secret \
        --from-file="features.conf=$WORK_DIR/features.conf" \
        --dry-run=client -o yaml | kubectl apply -f -
    rm -f "$WORK_DIR/features.conf"
    kubectl -n "$CLUSTER_NAMESPACE" create secret generic auth-secret \
        --from-literal="password=${ADMIN_PASSWORD}" \
        --dry-run=client -o yaml | kubectl apply -f -
    render_cluster_manifest
    wait_for_webhook
    kubectl apply -f "$WORK_DIR/aerospike-cluster.yaml"
    if ! kubectl -n "$CLUSTER_NAMESPACE" wait "aerospikecluster/${CLUSTER_NAME}" \
        --for=jsonpath='{.status.phase}'=Completed \
        --timeout="${STARTUP_TIMEOUT}s"; then
        dump_cluster_debug
        error "AerospikeCluster ${CLUSTER_NAME} did not reach Completed within ${STARTUP_TIMEOUT}s"
    fi
}

install_ingress() {
    helm repo add ingress-nginx "$INGRESS_NGINX_HELM_REPO" --force-update
    helm repo update
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace "$INGRESS_NAMESPACE" --create-namespace \
        --version "$INGRESS_NGINX_CHART_VERSION" \
        -f "$TEMPLATES/ingress-values.yaml" \
        --wait --timeout 10m
}

publish_outputs() {
    local i node_port
    local -a node_ports=() ingress_ports=()
    for ((i = 0; i < CLUSTER_SIZE; i++)); do
        node_port=$(kubectl -n "$CLUSTER_NAMESPACE" get "svc/${CLUSTER_NAME}-0-${i}" \
            -o jsonpath="{.spec.ports[?(@.port==${SERVICE_PORT})].nodePort}")
        [[ -n $node_port ]] || error "service ${CLUSTER_NAME}-0-${i} has no nodePort for service port ${SERVICE_PORT}"
        node_ports+=("$node_port")
        ingress_ports+=("$((INGRESS_PORT_BASE + i))")
    done

    write_output endpoint-hostname "$ENDPOINT_HOSTNAME"
    write_output ingress-ports "$(IFS=, && printf '%s' "${ingress_ports[*]}")"
    write_output kubeconfig "${KUBECONFIG:-${HOME}/.kube/config}"
    write_output service-node-ports "$(IFS=, && printf '%s' "${node_ports[*]}")"
}

run_group() {
    echo "::group::$1"
    "$2"
    echo "::endgroup::"
}

cmd_setup() {
    mkdir -p "$WORK_DIR"
    echo "::add-mask::${ADMIN_PASSWORD}"
    run_group "Label the node and add the CoreDNS entry" prepare_node
    run_group "Install cert-manager and AKO" install_ako
    run_group "Apply AerospikeCluster" deploy_cluster
    run_group "Install ingress-nginx and tcp-services" install_ingress
    publish_outputs
}

case ${1-} in
prepare) cmd_prepare ;;
setup) cmd_setup ;;
*) error "usage: entrypoint.sh prepare | setup" ;;
esac
