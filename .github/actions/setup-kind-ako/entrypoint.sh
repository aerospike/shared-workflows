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
PINNED_CHARTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deps/Chart.yaml"
WORK_DIR="${RUNNER_TEMP:-/tmp}/setup-kind-ako"

# The files in templates/ hardcode these names and ports; change both together.
CLUSTER_NAME="aerocluster"
CLUSTER_NAMESPACE="aerospike"
SERVICE_PORT=3000
INGRESS_PORT_BASE=9000
ENDPOINT_HOSTNAME="as-endpoint.test"
TLS_NAME="aerospike-tls"
AKO_NAMESPACE="ako"
INGRESS_NAMESPACE="ingress-nginx"
STARTUP_TIMEOUT=300
CERT_MANAGER_CHART_VERSION="v1.21.3"
CERT_MANAGER_HELM_REPO="https://charts.jetstack.io"
INGRESS_NGINX_CHART_VERSION="4.15.1"
INGRESS_NGINX_HELM_REPO="https://kubernetes.github.io/ingress-nginx"
ALTERNATE_ACCESS_LABEL="aerospike.com/configured-alternate-access-address"
VERSION_PATTERN='[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?'
RESOLVED_AKO_VERSION=""
ENDPOINT_NODE=""

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

apply_pinned_defaults() {
    local ako='.dependencies[] | select(.name == "aerospike-kubernetes-operator")'
    AKO_VERSION=${AKO_VERSION:-$(yq "$ako | .version" "$PINNED_CHARTS")}
    AKO_HELM_REPO=${AKO_HELM_REPO:-$(yq "$ako | .repository" "$PINNED_CHARTS")}
}

cmd_prepare() {
    local password=${ADMIN_PASSWORD-}
    apply_pinned_defaults
    [[ -n ${FEATURES_CONTENT-} ]] || error "features-content is required"
    [[ $CLUSTER_SIZE =~ ^[1-8]$ ]] || error "cluster-size must be 1-8 (got: '$CLUSTER_SIZE')"
    [[ $SERVER_IMAGE =~ ^[A-Za-z0-9._:/-]+:[A-Za-z0-9._-]+$ ]] ||
        error "server-image must be repository:tag (got: '$SERVER_IMAGE')"
    [[ $ENABLE_TLS == true || $ENABLE_TLS == false ]] ||
        error "enable-tls must be true or false (got: '$ENABLE_TLS')"
    [[ $AKO_VERSION == latest || $AKO_VERSION =~ ^${VERSION_PATTERN}$ ]] ||
        error "ako-version must be latest or a chart version such as 4.8.0-dev1 (got: '$AKO_VERSION')"
    [[ $AKO_HELM_REPO =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$ ]] ||
        error "ako-helm-repo must be an https URL (got: '$AKO_HELM_REPO')"
    [[ -z $CLUSTER_CHART_VERSION || $CLUSTER_CHART_VERSION =~ ^${VERSION_PATTERN}$ ]] ||
        error "cluster-chart-version must be empty or a chart version such as 4.7.0 (got: '$CLUSTER_CHART_VERSION')"
    if [[ $AKO_VERSION == *-dev* && -z $CLUSTER_CHART_VERSION ]]; then
        error "ako-version ${AKO_VERSION} needs cluster-chart-version; dev builds publish no aerospike-cluster chart"
    fi
    [[ $KIND_NODE_IMAGE =~ ^[A-Za-z0-9._:/-]+:[A-Za-z0-9._-]+(@sha256:[0-9a-f]{64})?$ ]] ||
        error "kind-node-image must be repository:tag (got: '$KIND_NODE_IMAGE')"
    [[ $ALTERNATE_ACCESS == configuredIP || $ALTERNATE_ACCESS == networkLoadBalancer ]] ||
        error "alternate-access must be configuredIP or networkLoadBalancer (got: '$ALTERNATE_ACCESS')"
    [[ $MULTI_POD_PER_HOST == true || $MULTI_POD_PER_HOST == false ]] ||
        error "multi-pod-per-host must be true or false (got: '$MULTI_POD_PER_HOST')"
    if [[ $MULTI_POD_PER_HOST == false && $ALTERNATE_ACCESS != networkLoadBalancer ]]; then
        error "multi-pod-per-host false needs alternate-access networkLoadBalancer; configuredIP labels every node with one address"
    fi
    if [[ -z $password ]]; then
        password=$(openssl rand -hex 16)
    fi
    [[ $password =~ ^[A-Za-z0-9]{8,128}$ ]] || error "admin-password must be 8-128 letters or digits"
    echo "::add-mask::${password}"
    write_output admin-password "$password"
    write_kind_config
}

# One pod per node, plus a spare node to scale up by one or reschedule a pod.
write_kind_config() {
    local i
    if [[ $MULTI_POD_PER_HOST == true ]]; then
        return 0
    fi
    mkdir -p "$WORK_DIR"
    {
        printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n  - role: control-plane\n'
        for ((i = 0; i <= CLUSTER_SIZE; i++)); do
            printf '  - role: worker\n'
        done
    } >"$WORK_DIR/kind-config.yaml"
    write_output kind-config "$WORK_DIR/kind-config.yaml"
}

prepare_node() {
    local ip corefile
    kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || true
    kubectl taint nodes --all node-role.kubernetes.io/master:NoSchedule- || true
    if [[ $ALTERNATE_ACCESS == configuredIP ]]; then
        # ENDPOINT_HOSTNAME is a DNS name. This label is an IP field; AKO copies
        # it through without validating. alternate-access networkLoadBalancer
        # advertises the hostname from the CR instead and needs no label. Label
        # values are also limited to 63 characters, so this cannot hold a real PrivateLink name.
        kubectl label nodes --all "${ALTERNATE_ACCESS_LABEL}=${ENDPOINT_HOSTNAME}" --overwrite
    fi

    ENDPOINT_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
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

# helm search, like helm install without --version, skips prereleases.
resolve_ako_version() {
    local version=$AKO_VERSION
    if [[ $version == latest ]]; then
        version=$(helm search repo aerospike/aerospike-kubernetes-operator -o json |
            jq -r '.[] | select(.name == "aerospike/aerospike-kubernetes-operator") | .version')
        [[ -n $version ]] || error "no aerospike-kubernetes-operator chart in $AKO_HELM_REPO"
    fi
    RESOLVED_AKO_VERSION=$version
    echo "AKO chart version: ${RESOLVED_AKO_VERSION}"
}

install_ako() {
    helm repo add jetstack "$CERT_MANAGER_HELM_REPO" --force-update
    helm repo add aerospike "$AKO_HELM_REPO" --force-update
    helm repo update
    resolve_ako_version
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --version "$CERT_MANAGER_CHART_VERSION" \
        --set crds.enabled=true \
        --wait --timeout 10m
    kubectl create namespace "$CLUSTER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install aerospike-kubernetes-operator aerospike/aerospike-kubernetes-operator \
        --namespace "$AKO_NAMESPACE" --create-namespace \
        --version "$RESOLVED_AKO_VERSION" \
        --set "watchNamespaces=${CLUSTER_NAMESPACE}" \
        --wait --timeout 10m
    kubectl wait --for=condition=Established crd/aerospikeclusters.asdb.aerospike.com --timeout=180s
    kubectl get clusterrole aerospike-cluster >/dev/null
    kubectl apply -f "$TEMPLATES/rbac.yaml"
    if [[ $ALTERNATE_ACCESS == networkLoadBalancer ]]; then
        check_alternate_access
    fi
}

check_alternate_access() {
    local types
    types=$(kubectl get crd aerospikeclusters.asdb.aerospike.com -o jsonpath='{.spec.versions[*].schema.openAPIV3Schema.properties.spec.properties.aerospikeNetworkPolicy.properties.alternateAccess.enum}')
    [[ $types == *'"networkLoadBalancer"'* ]] ||
        error "AKO ${RESOLVED_AKO_VERSION} does not offer alternateAccess networkLoadBalancer; alternate-access networkLoadBalancer needs an ako-version that supports it"
}

render_cluster_manifest() {
    local rf=1
    local -a values=(-f "$TEMPLATES/aerospike-cluster-values.yaml")
    if ((CLUSTER_SIZE >= 2)); then
        rf=2
    fi
    if [[ $ENABLE_TLS == true ]]; then
        values+=(-f "$TEMPLATES/aerospike-cluster-tls-values.yaml")
    fi
    if [[ $ALTERNATE_ACCESS == networkLoadBalancer ]]; then
        values+=(--set aerospikeNetworkPolicy.alternateAccess=networkLoadBalancer)
        values+=(--set-string "aerospikeNetworkPolicy.loadBalancerAlternateAccessAddress=${ENDPOINT_HOSTNAME}")
        if [[ $ENABLE_TLS == true ]]; then
            values+=(--set aerospikeNetworkPolicy.tlsAlternateAccess=networkLoadBalancer)
            values+=(--set-string "aerospikeNetworkPolicy.loadBalancerTLSAlternateAccessAddress=${ENDPOINT_HOSTNAME}")
        fi
    fi
    if [[ $MULTI_POD_PER_HOST == false ]]; then
        values+=(--set podSpec.multiPodPerHost=false)
    fi
    helm template "$CLUSTER_NAME" aerospike/aerospike-cluster \
        --namespace "$CLUSTER_NAMESPACE" \
        --version "${CLUSTER_CHART_VERSION:-$RESOLVED_AKO_VERSION}" \
        "${values[@]}" \
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

# A CA and a server certificate whose only SAN is the dNSName TLS_NAME, so a
# client must validate each node against the tls-name the cluster advertises,
# not the endpoint hostname it dials.
generate_tls() {
    local dir="$WORK_DIR/tls"
    mkdir -p "$dir"
    printf '[v3_req]\nsubjectAltName = DNS:%s\n' "$TLS_NAME" >"$dir/san.ext"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/ca.key" -out "$dir/ca.crt" -days 30 \
        -subj "/CN=setup-kind-ako test CA"
    openssl req -newkey rsa:2048 -nodes -keyout "$dir/server.key" -out "$dir/server.csr" \
        -subj "/CN=${TLS_NAME}"
    openssl x509 -req -in "$dir/server.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -CAcreateserial \
        -out "$dir/server.crt" -days 30 -extensions v3_req -extfile "$dir/san.ext"
    rm -f "$dir/ca.key" "$dir/ca.srl" "$dir/server.csr" "$dir/san.ext"
    openssl x509 -in "$dir/server.crt" -noout -subject -ext subjectAltName
}

deploy_cluster() {
    local -a files=()
    printf '%s' "$FEATURES_CONTENT" >"$WORK_DIR/features.conf"
    files+=("--from-file=features.conf=$WORK_DIR/features.conf")
    if [[ $ENABLE_TLS == true ]]; then
        generate_tls
        files+=("--from-file=ca.crt=$WORK_DIR/tls/ca.crt")
        files+=("--from-file=server.crt=$WORK_DIR/tls/server.crt")
        files+=("--from-file=server.key=$WORK_DIR/tls/server.key")
    fi
    kubectl -n "$CLUSTER_NAMESPACE" create secret generic aerospike-secret "${files[@]}" \
        --dry-run=client -o yaml | kubectl apply -f -
    rm -f "$WORK_DIR/features.conf" "$WORK_DIR/tls/server.key"
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
    if [[ $MULTI_POD_PER_HOST == false ]]; then
        serve_node_ports_on_every_node
    fi
}

# AKO creates each pod Service with externalTrafficPolicy Local, so its NodePort
# answers only on the pod's node. The endpoint hostname resolves to one node, as
# an NLB address would front them all. AKO does not reset the policy on update.
serve_node_ports_on_every_node() {
    local i
    for ((i = 0; i < CLUSTER_SIZE; i++)); do
        kubectl -n "$CLUSTER_NAMESPACE" patch "svc/${CLUSTER_NAME}-0-${i}" \
            -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
    done
}

install_ingress() {
    local -a ingress_args=()
    # The controller binds its tcp-services hostPorts on the node the endpoint hostname resolves to.
    if [[ $MULTI_POD_PER_HOST == false ]]; then
        ingress_args+=(--set-string "controller.nodeSelector.kubernetes\\.io/hostname=${ENDPOINT_NODE}")
    fi
    helm repo add ingress-nginx "$INGRESS_NGINX_HELM_REPO" --force-update
    helm repo update
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace "$INGRESS_NAMESPACE" --create-namespace \
        --version "$INGRESS_NGINX_CHART_VERSION" \
        -f "$TEMPLATES/ingress-values.yaml" \
        "${ingress_args[@]}" \
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

    write_output alternate-access "$ALTERNATE_ACCESS"
    write_output endpoint-hostname "$ENDPOINT_HOSTNAME"
    write_output ingress-ports "$(IFS=, && printf '%s' "${ingress_ports[*]}")"
    write_output kubeconfig "${KUBECONFIG:-${HOME}/.kube/config}"
    write_output service-node-ports "$(IFS=, && printf '%s' "${node_ports[*]}")"
    if [[ $ENABLE_TLS == true ]]; then
        write_output tls-ca-file "$WORK_DIR/tls/ca.crt"
        write_output tls-name "$TLS_NAME"
    fi
}

run_group() {
    echo "::group::$1"
    "$2"
    echo "::endgroup::"
}

cmd_setup() {
    apply_pinned_defaults
    mkdir -p "$WORK_DIR"
    echo "::add-mask::${ADMIN_PASSWORD}"
    if [[ $ALTERNATE_ACCESS == configuredIP ]]; then
        run_group "Label the node and add the CoreDNS entry" prepare_node
    else
        run_group "Add the CoreDNS entry" prepare_node
    fi
    run_group "Install cert-manager and AKO" install_ako
    run_group "Apply AerospikeCluster" deploy_cluster
    run_group "Install ingress-nginx and tcp-services" install_ingress
    publish_outputs
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case ${1-} in
    prepare) cmd_prepare ;;
    setup) cmd_setup ;;
    *) error "usage: entrypoint.sh prepare | setup" ;;
    esac
fi
