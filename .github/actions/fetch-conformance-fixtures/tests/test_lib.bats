#!/usr/bin/env bats
# Tests for fetch-conformance-fixtures path checks, dry-run, and extraction.
# shellcheck disable=SC2030,SC2031 # each @test is a subshell; exports are intentional

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/fetch-conformance-fixtures"
FIXTURE_VERSION="$(tr -d '[:space:]' < "$ACTION_DIR/fixture-set-version")"
ARTIFACT_PATH="database-generic-dev-local/aerospike-client-conformance/${FIXTURE_VERSION}/aerospike-client-conformance-${FIXTURE_VERSION}.zip"
RELEASE_PREFIX="aerospike-client-conformance-${FIXTURE_VERSION}"

# shellcheck source=/dev/null
source "$ACTION_DIR/lib.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
    export GITHUB_WORKSPACE="$TEST_TMPDIR"
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset DRY_RUN VERSION PACKAGE_NAME JF_PROJECT DESTINATION
    unset OIDC_PROVIDER_NAME OIDC_AUDIENCE GITHUB_OUTPUT GITHUB_WORKSPACE
    unset FAKE_RELEASE_ZIP
}

# Lay out an unpacked release with VERSION and one fixture file.
make_release_tree() {
    local version_text=$1
    local root="$TEST_TMPDIR/src/$RELEASE_PREFIX"
    mkdir -p "$root/tls"
    printf '%s\n' "$version_text" >"$root/VERSION"
    printf 'kind: tls\n' >"$root/tls/name-matching.yaml"
}

# Zip the release tree the way git archive does, with one top-level directory.
pack_release() {
    mkdir -p "$TEST_TMPDIR/release"
    export FAKE_RELEASE_ZIP="$TEST_TMPDIR/release/${RELEASE_PREFIX}.zip"
    (cd "$TEST_TMPDIR/src" && zip -qry "$FAKE_RELEASE_ZIP" "$RELEASE_PREFIX")
}

# Run a real fetch with a fake jf that copies FAKE_RELEASE_ZIP into the download directory.
run_fetch() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat >"$TEST_TMPDIR/bin/jf" <<'EOF'
#!/usr/bin/env bash
# Called as: jf rt download <artifact> <directory>/ ...
cp "$FAKE_RELEASE_ZIP" "$4"
EOF
    chmod +x "$TEST_TMPDIR/bin/jf"

    export PATH="$TEST_TMPDIR/bin:$PATH"
    export VERSION="$FIXTURE_VERSION"
    export DRY_RUN=false
    export DESTINATION=conformance-fixtures
    export OIDC_PROVIDER_NAME=test-provider
    export OIDC_AUDIENCE=test-audience
    export GITHUB_OUTPUT="$TEST_TMPDIR/output"

    run "$ACTION_DIR/entrypoint.sh" fetch
}

@test "artifact path matches the conformance release layout" {
    run artifact_repo_path "database" "aerospike-client-conformance" "$FIXTURE_VERSION"

    [ "$status" -eq 0 ]
    [ "$output" = "$ARTIFACT_PATH" ]
}

@test "version rejects a v prefix and a partial semver" {
    run validate_semver "v${FIXTURE_VERSION}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MAJOR.MINOR.PATCH"* ]]

    partial="${FIXTURE_VERSION%.*}"
    run validate_semver "$partial"
    [ "$status" -ne 0 ]
}

@test "destination stays under the workspace" {
    run resolve_destination "conformance-fixtures"
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/conformance-fixtures" ]

    run resolve_destination "../escape"
    [ "$status" -ne 0 ]

    run resolve_destination "/tmp/fixtures"
    [ "$status" -ne 0 ]

    run resolve_destination "."
    [ "$status" -ne 0 ]
}

@test "dry-run prints the download and does not require jf or oidc" {
    export VERSION="$FIXTURE_VERSION"
    export DRY_RUN=true
    export DESTINATION=conformance-fixtures
    export GITHUB_OUTPUT="$TEST_TMPDIR/output"

    run "$ACTION_DIR/entrypoint.sh" fetch

    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run: jf rt download ${ARTIFACT_PATH}"* ]]
    grep -q "^artifact-path=${ARTIFACT_PATH}$" "$GITHUB_OUTPUT"
    run grep -q '^fixtures-directory=' "$GITHUB_OUTPUT"
    [ "$status" -ne 0 ]
}

@test "a real fetch without oidc fails before download" {
    export VERSION="$FIXTURE_VERSION"
    export DRY_RUN=false

    run "$ACTION_DIR/entrypoint.sh" validate

    [ "$status" -ne 0 ]
    [[ "$output" == *"oidc-provider-name"* ]]
}

@test "fetch strips the release prefix and puts VERSION at the destination root" {
    make_release_tree "$FIXTURE_VERSION"
    pack_release

    run_fetch

    [ "$status" -eq 0 ]
    dest="$TEST_TMPDIR/conformance-fixtures"
    [ "$(cat "$dest/VERSION")" = "$FIXTURE_VERSION" ]
    [ -f "$dest/tls/name-matching.yaml" ]
    [ ! -e "$dest/$RELEASE_PREFIX" ]
    grep -q "^fixtures-directory=${dest}$" "$GITHUB_OUTPUT"
    grep -q "^fixture-set-version=${FIXTURE_VERSION}$" "$GITHUB_OUTPUT"
}

@test "fetch rejects a release whose VERSION does not match" {
    make_release_tree "9.9.9"
    pack_release

    run_fetch

    [ "$status" -ne 0 ]
    [[ "$output" == *"VERSION is 9.9.9, expected ${FIXTURE_VERSION}"* ]]
    [ ! -e "$TEST_TMPDIR/conformance-fixtures" ]
}

@test "fetch rejects a release that contains a symlink" {
    make_release_tree "$FIXTURE_VERSION"
    ln -s /etc/passwd "$TEST_TMPDIR/src/$RELEASE_PREFIX/link"
    pack_release

    run_fetch

    [ "$status" -ne 0 ]
    [[ "$output" == *"release zip contains a symlink"* ]]
    [ ! -e "$TEST_TMPDIR/conformance-fixtures" ]
}

@test "fetch keeps a ../ entry inside the extract directory" {
    mkdir -p "$TEST_TMPDIR/release"
    export FAKE_RELEASE_ZIP="$TEST_TMPDIR/release/${RELEASE_PREFIX}.zip"
    # The zip command normalizes ../ away, so build this entry with Python.
    python3 - "$FAKE_RELEASE_ZIP" "$RELEASE_PREFIX" "$FIXTURE_VERSION" <<'EOF'
import sys
import zipfile

zip_path, prefix, version = sys.argv[1:]
with zipfile.ZipFile(zip_path, "w") as archive:
    archive.writestr(f"{prefix}/VERSION", f"{version}\n")
    archive.writestr(f"{prefix}/../../outside", "nope")
EOF

    run_fetch

    [ ! -e "$TEST_TMPDIR/outside" ]
    [ ! -e "$TEST_TMPDIR/../outside" ]
}

@test "fetch refuses a destination that is not empty" {
    make_release_tree "$FIXTURE_VERSION"
    pack_release
    mkdir -p "$TEST_TMPDIR/conformance-fixtures"
    touch "$TEST_TMPDIR/conformance-fixtures/leftover"

    run_fetch

    [ "$status" -ne 0 ]
    [[ "$output" == *"destination is not empty"* ]]
}
