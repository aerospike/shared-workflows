#!/usr/bin/env bats
# Tests for setup-kind-ako that do not need a cluster. helm, kubectl and sudo are stubs.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ENTRYPOINT="$GIT_ROOT/.github/actions/setup-kind-ako/entrypoint.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export RUNNER_TEMP="$TEST_TMPDIR"
    export GITHUB_OUTPUT="$TEST_TMPDIR/output"
    export CLUSTER_SIZE=1
    export ENABLE_TLS=false
    export SERVER_IMAGE=aerospike/aerospike-server-enterprise:8.1.2.5
    export FEATURES_CONTENT=feature-key
    export ADMIN_PASSWORD=testpassword
    export AKO_VERSION=latest
    export AKO_HELM_REPO=https://aerospike.github.io/aerospike-kubernetes-operator
    export CLUSTER_CHART_VERSION=""
    export KIND_NODE_IMAGE=kindest/node:v1.35.0
    export ALTERNATE_ACCESS=configuredIP
    export MULTI_POD_PER_HOST=true
    export CALLS="$TEST_TMPDIR/calls"
    export CRD_ENUM='["pod","hostInternal","hostExternal","configuredIP","customInterface"]'
    WORK_DIR="$TEST_TMPDIR/setup-kind-ako"
    MANIFEST="$WORK_DIR/aerospike-cluster.yaml"
    mkdir -p "$WORK_DIR" "$TEST_TMPDIR/bin"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    cat >"$TEST_TMPDIR/bin/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >>"$CALLS"
case $1 in
search) echo '[{"name":"aerospike/aerospike-kubernetes-operator","version":"4.7.0"}]' ;;
template) printf '%s\n' "$@" ;;
esac
EOF
    cat >"$TEST_TMPDIR/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS"
case "$*" in
*"get crd"*) printf '%s' "$CRD_ENUM" ;;
*"get cm coredns"*) printf '.:53 {\n    errors\n}\n' ;;
*"get nodes"*) printf '172.18.0.2' ;;
esac
EOF
    cat >"$TEST_TMPDIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
    chmod +x "$TEST_TMPDIR/bin/"*
}

# Runs one entrypoint.sh function after the given shell statements.
run_function() {
    run bash -c "source '$ENTRYPOINT'; $1"
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

@test "prepare writes the given password" {
    run "$ENTRYPOINT" prepare

    [ "$status" -eq 0 ]
    [[ "$output" == *"::add-mask::testpassword"* ]]
    grep -qx 'admin-password=testpassword' "$GITHUB_OUTPUT"
}

@test "prepare generates a password when none is given" {
    ADMIN_PASSWORD="" run "$ENTRYPOINT" prepare

    [ "$status" -eq 0 ]
    grep -Eqx 'admin-password=[0-9a-f]{32}' "$GITHUB_OUTPUT"
}

@test "prepare rejects a missing feature key" {
    FEATURES_CONTENT="" run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"features-content is required"* ]]
}

@test "prepare rejects a password with symbols" {
    ADMIN_PASSWORD='bad pass;word' run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"admin-password must be 8-128 letters or digits"* ]]
}

@test "prepare rejects cluster-size outside 1-8" {
    CLUSTER_SIZE=9 run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster-size must be 1-8"* ]]

    CLUSTER_SIZE=0 run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
}

@test "prepare rejects a server-image with YAML characters" {
    SERVER_IMAGE='aerospike/server:1 # x' run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"server-image"* ]]
}

@test "prepare rejects a server-image without a tag" {
    SERVER_IMAGE=aerospike/aerospike-server-enterprise@sha256:0123abcd run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"server-image must be repository:tag"* ]]
}

@test "prepare accepts enable-tls true" {
    ENABLE_TLS=true run "$ENTRYPOINT" prepare

    [ "$status" -eq 0 ]
}

@test "prepare rejects enable-tls other than true or false" {
    ENABLE_TLS=yes run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"enable-tls must be true or false"* ]]
}

@test "prepare accepts a named ako-version and a cluster-chart-version" {
    AKO_VERSION=4.8.0-dev1 CLUSTER_CHART_VERSION=4.7.0 run "$ENTRYPOINT" prepare

    [ "$status" -eq 0 ]
}

@test "prepare rejects a dev ako-version without cluster-chart-version" {
    AKO_VERSION=4.8.0-dev1 run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"ako-version 4.8.0-dev1 needs cluster-chart-version"* ]]
}

@test "empty ako-version and ako-helm-repo take a released version and an https repo from deps/Chart.yaml" {
    AKO_VERSION="" AKO_HELM_REPO="" run_function 'apply_pinned_defaults; echo "$AKO_VERSION $AKO_HELM_REPO"'

    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+\ https://[^\ ]+$ ]]
}

@test "prepare rejects an ako-version that is neither latest nor a chart version" {
    AKO_VERSION=v4.7 run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"ako-version must be latest or a chart version"* ]]
}

@test "prepare rejects an ako-helm-repo that is not an https URL" {
    AKO_HELM_REPO=http://aerospike.github.io/aerospike-kubernetes-operator run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"ako-helm-repo must be an https URL"* ]]
}

@test "prepare rejects a cluster-chart-version that is not a chart version" {
    CLUSTER_CHART_VERSION=latest run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster-chart-version must be empty or a chart version"* ]]
}

@test "prepare rejects a kind-node-image without a tag" {
    KIND_NODE_IMAGE=kindest/node run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"kind-node-image must be repository:tag"* ]]
}

@test "prepare rejects an unknown alternate-access" {
    ALTERNATE_ACCESS=hostExternal run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"alternate-access must be configuredIP or networkLoadBalancer"* ]]
}

@test "prepare rejects multi-pod-per-host other than true or false" {
    MULTI_POD_PER_HOST=no run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"multi-pod-per-host must be true or false"* ]]
}

@test "prepare rejects multi-pod-per-host false with configuredIP" {
    MULTI_POD_PER_HOST=false run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"multi-pod-per-host false needs alternate-access networkLoadBalancer"* ]]
}

@test "prepare writes no kind config for one pod node" {
    run "$ENTRYPOINT" prepare

    [ "$status" -eq 0 ]
    ! grep -q '^kind-config=' "$GITHUB_OUTPUT" || false
}

@test "prepare writes a kind config with cluster-size + 1 workers for multi-pod-per-host false" {
    CLUSTER_SIZE=3 ALTERNATE_ACCESS=networkLoadBalancer MULTI_POD_PER_HOST=false run "$ENTRYPOINT" prepare

    [ "$status" -eq 0 ]
    grep -qx "kind-config=$WORK_DIR/kind-config.yaml" "$GITHUB_OUTPUT"
    [ "$(grep -c -- '- role: control-plane' "$WORK_DIR/kind-config.yaml")" -eq 1 ]
    [ "$(grep -c -- '- role: worker' "$WORK_DIR/kind-config.yaml")" -eq 4 ]
}

@test "latest resolves to the newest released chart and is printed" {
    run_function 'resolve_ako_version; echo "resolved=$RESOLVED_AKO_VERSION"'

    [ "$status" -eq 0 ]
    [[ "$output" == *"AKO chart version: 4.7.0"* ]]
    [[ "$output" == *"resolved=4.7.0"* ]]
}

@test "a named ako-version is used without searching the repo" {
    AKO_VERSION=4.8.0-dev1 run_function 'resolve_ako_version'

    [ "$status" -eq 0 ]
    [[ "$output" == *"AKO chart version: 4.8.0-dev1"* ]]
    ! grep -q 'helm search' "$CALLS" || false
}

@test "install_ako installs the named ako-version" {
    AKO_VERSION=4.5.0 run_function 'install_ako'

    [ "$status" -eq 0 ]
    grep -q 'aerospike-kubernetes-operator .*--version 4.5.0 ' "$CALLS"
}

@test "networkLoadBalancer fails after the AKO install when the CRD lacks it" {
    ALTERNATE_ACCESS=networkLoadBalancer run_function 'install_ako'

    [ "$status" -ne 0 ]
    [[ "$output" == *"AKO 4.7.0 does not offer alternateAccess networkLoadBalancer"* ]]
    [[ "$output" == *"needs an ako-version that supports it"* ]]
    grep -q 'helm upgrade --install aerospike-kubernetes-operator' "$CALLS"
    grep -q 'kubectl get crd aerospikeclusters.asdb.aerospike.com' "$CALLS"
}

@test "networkLoadBalancer passes the CRD check when the CRD offers it" {
    CRD_ENUM='["pod","hostInternal","hostExternal","configuredIP","customInterface","networkLoadBalancer"]' \
        ALTERNATE_ACCESS=networkLoadBalancer AKO_VERSION=4.8.0-dev1 run_function 'install_ako'

    [ "$status" -eq 0 ]
    grep -q 'kubectl get crd aerospikeclusters.asdb.aerospike.com' "$CALLS"
}

@test "configuredIP skips the CRD check" {
    run_function 'install_ako'

    [ "$status" -eq 0 ]
    ! grep -q 'get crd aerospikeclusters.asdb.aerospike.com -o' "$CALLS" || false
}

@test "configuredIP labels every node" {
    run_function 'prepare_node'

    [ "$status" -eq 0 ]
    grep -qx 'kubectl label nodes --all aerospike.com/configured-alternate-access-address=as-endpoint.test --overwrite' "$CALLS"
    grep -q '172.18.0.2 as-endpoint.test' "$WORK_DIR/Corefile"
}

@test "networkLoadBalancer labels no node and keeps the CoreDNS entry" {
    ALTERNATE_ACCESS=networkLoadBalancer run_function 'prepare_node'

    [ "$status" -eq 0 ]
    ! grep -q 'kubectl label' "$CALLS" || false
    grep -q '172.18.0.2 as-endpoint.test' "$WORK_DIR/Corefile"
}

@test "configuredIP renders the base values with the AKO chart version" {
    run_function 'RESOLVED_AKO_VERSION=4.5.0; render_cluster_manifest'

    [ "$status" -eq 0 ]
    grep -qx -- '--version' "$MANIFEST"
    grep -A1 -x -- '--version' "$MANIFEST" | grep -qx '4.5.0'
    ! grep -q 'networkLoadBalancer\|multiPodPerHost\|aerospike-cluster-tls-values' "$MANIFEST" || false
}

@test "networkLoadBalancer renders the alternate access address" {
    ALTERNATE_ACCESS=networkLoadBalancer CLUSTER_CHART_VERSION=4.7.0 \
        run_function 'RESOLVED_AKO_VERSION=4.8.0-dev1; render_cluster_manifest'

    [ "$status" -eq 0 ]
    grep -A1 -x -- '--version' "$MANIFEST" | grep -qx '4.7.0'
    grep -qx 'aerospikeNetworkPolicy.alternateAccess=networkLoadBalancer' "$MANIFEST"
    grep -qx 'aerospikeNetworkPolicy.loadBalancerAlternateAccessAddress=as-endpoint.test' "$MANIFEST"
    ! grep -q 'tlsAlternateAccess\|loadBalancerTLSAlternateAccessAddress\|multiPodPerHost' "$MANIFEST" || false
}

@test "networkLoadBalancer with TLS renders the TLS alternate access address" {
    ALTERNATE_ACCESS=networkLoadBalancer ENABLE_TLS=true \
        run_function 'RESOLVED_AKO_VERSION=4.8.0-dev1; render_cluster_manifest'

    [ "$status" -eq 0 ]
    grep -q 'aerospike-cluster-tls-values.yaml$' "$MANIFEST"
    grep -qx 'aerospikeNetworkPolicy.alternateAccess=networkLoadBalancer' "$MANIFEST"
    grep -qx 'aerospikeNetworkPolicy.tlsAlternateAccess=networkLoadBalancer' "$MANIFEST"
    grep -qx 'aerospikeNetworkPolicy.loadBalancerTLSAlternateAccessAddress=as-endpoint.test' "$MANIFEST"
}

@test "multi-pod-per-host false renders multiPodPerHost false" {
    ALTERNATE_ACCESS=networkLoadBalancer MULTI_POD_PER_HOST=false \
        run_function 'RESOLVED_AKO_VERSION=4.8.0-dev1; render_cluster_manifest'

    [ "$status" -eq 0 ]
    grep -qx 'podSpec.multiPodPerHost=false' "$MANIFEST"
}
