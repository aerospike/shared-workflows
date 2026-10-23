#!/usr/bin/env bats
# Docker/OCI bundle metadata (docker-images.json) from type_detection.sh.
# A Lifecycle release-bundle-record.json is the source of truth; a pre-written
# docker-images.json is staged only when that record is absent.

load '../helpers/setup'

setup() {
    local _base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
    mkdir -p "$_base"
    DOCKER_BUNDLE_TEST_DIR=$(mktemp -d "${_base%/}/docker-bundle.XXXXXX")
    export DOCKER_BUNDLE_TEST_DIR
}

teardown() {
    if [[ -n ${DOCKER_BUNDLE_TEST_DIR:-} && -d ${DOCKER_BUNDLE_TEST_DIR} ]]; then
        rm -rf "${DOCKER_BUNDLE_TEST_DIR}"
    fi
    unset DOCKER_BUNDLE_TEST_DIR || true
}

# detect_types.sh sources type_registry.sh (declare -A); requires bash 4+.
_require_bash4_for_detect_types() {
    ((BASH_VERSINFO[0] >= 4)) || skip "requires bash 4+ for detect_types (type_registry associative arrays)"
}

_new_artifacts_wd() {
    local wd="${DOCKER_BUNDLE_TEST_DIR}/$1"
    mkdir -p "$wd/build-artifacts"
    printf '%s\n' "$wd"
}

# Observed bundle layout: tag manifests plus digest dirs. These files are not images.
_plant_container_files() {
    local root="$1"
    mkdir -p \
        "$root/artifacts/docker/aerospike-server/8.1.0.0" \
        "$root/artifacts/docker/aerospike-server/sha256__aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "$root/artifacts/oci/absctl/1.2.0_20260929T144224Z" \
        "$root/artifacts/oci/absctl/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "$root/artifacts/oci/aerospike-backup-service/3.7.0_20260929T140341Z"
    printf '%s\n' '{}' >"$root/artifacts/docker/aerospike-server/8.1.0.0/list.manifest.json"
    printf '%s\n' '{}' >"$root/artifacts/docker/aerospike-server/sha256__aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/manifest.json"
    printf '%s\n' 'blob' >"$root/artifacts/docker/aerospike-server/sha256__aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/sha256__cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    printf '%s\n' '{}' >"$root/artifacts/oci/absctl/1.2.0_20260929T144224Z/list.manifest.json"
    printf '%s\n' '{}' >"$root/artifacts/oci/absctl/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/manifest.json"
    printf '%s\n' '{}' >"$root/artifacts/oci/aerospike-backup-service/3.7.0_20260929T140341Z/list.manifest.json"
}

_assert_manifest_generic() {
    local manifest="$1"
    grep -qE 'generic/docker/docker-images\.json[[:space:]]+generic$' "$manifest" ||
        (echo "docker-images.json missing from manifest as generic:" >&2 && cat "$manifest" >&2 && return 1)
    ! grep -qE 'docker-images\.json[[:space:]]+docker$' "$manifest"
}

@test "docker tag row is written to docker-images.json and listed as generic" {
    _require_bash4_for_detect_types
    local wd root out
    wd=$(_new_artifacts_wd docker-tag)
    root="$wd/build-artifacts"
    _plant_container_files "$root"
    cat >"$root/release-bundle-record.json" <<'EOF'
{
  "artifacts": [
    {
      "path": "artifacts/docker/aerospike-server/8.1.0.0/list.manifest.json",
      "source_repository_key": "database-docker-dev-local",
      "package_type": "docker",
      "package_version": "8.1.0.0",
      "package_name": "aerospike-server"
    }
  ]
}
EOF

    (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)

    out="$wd/structured_build_artifacts/generic/docker/docker-images.json"
    [[ -f $out ]]
    [[ "$(cat "$out")" == '{"package_name":"aerospike-server","package_version":"8.1.0.0","source_repository_key":"database-docker-dev-local"}' ]]
    _assert_manifest_generic "$wd/structured_build_artifacts/.manifest"
    [[ "$(find "$wd/structured_build_artifacts" -name 'docker-images.json' | wc -l | tr -d ' ')" == "1" ]]
}

@test "oci tag rows are written the same way as docker tags" {
    _require_bash4_for_detect_types
    local wd root out
    wd=$(_new_artifacts_wd oci-tags)
    root="$wd/build-artifacts"
    _plant_container_files "$root"
    cat >"$root/release-bundle-record.json" <<'EOF'
{
  "artifacts": [
    {
      "path": "artifacts/oci/absctl/1.2.0_20260929T144224Z/list.manifest.json",
      "package_type": "oci",
      "package_name": "absctl",
      "package_version": "1.2.0_20260929T144224Z",
      "source_repository_key": "database-oci-dev-local"
    },
    {
      "path": "artifacts/oci/aerospike-backup-service/3.7.0_20260929T140341Z/list.manifest.json",
      "package_type": "oci",
      "package_name": "aerospike-backup-service",
      "package_version": "3.7.0_20260929T140341Z",
      "source_repository_key": "database-oci-dev-local"
    }
  ]
}
EOF

    (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)

    out="$wd/structured_build_artifacts/generic/docker/docker-images.json"
    [[ -f $out ]]
    [[ "$(sed -n '1p' "$out")" == '{"package_name":"absctl","package_version":"1.2.0_20260929T144224Z","source_repository_key":"database-oci-dev-local"}' ]]
    [[ "$(sed -n '2p' "$out")" == '{"package_name":"aerospike-backup-service","package_version":"3.7.0_20260929T140341Z","source_repository_key":"database-oci-dev-local"}' ]]
    [[ "$(grep -c . "$out")" == "2" ]]
    _assert_manifest_generic "$wd/structured_build_artifacts/.manifest"
}

@test "docker and oci digest rows are omitted" {
    _require_bash4_for_detect_types
    local wd root out
    wd=$(_new_artifacts_wd digests)
    root="$wd/build-artifacts"
    _plant_container_files "$root"
    cat >"$root/release-bundle-record.json" <<'EOF'
{
  "artifacts": [
    {
      "path": "artifacts/docker/aerospike-server/8.1.0.0/list.manifest.json",
      "package_type": "docker",
      "package_name": "aerospike-server",
      "package_version": "8.1.0.0",
      "source_repository_key": "database-docker-dev-local"
    },
    {
      "path": "artifacts/docker/aerospike-server/sha256__aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/manifest.json",
      "package_type": "docker",
      "package_name": "aerospike-server",
      "package_version": "sha256__aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "source_repository_key": "database-docker-dev-local"
    },
    {
      "path": "artifacts/oci/absctl/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/manifest.json",
      "package_type": "oci",
      "package_name": "absctl",
      "package_version": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "source_repository_key": "database-oci-dev-local"
    },
    {
      "path": "artifacts/oci/absctl/1.2.0_20260929T144224Z/list.manifest.json",
      "package_type": "oci",
      "package_name": "absctl",
      "package_version": "1.2.0_20260929T144224Z",
      "source_repository_key": "database-oci-dev-local"
    }
  ]
}
EOF

    (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)

    out="$wd/structured_build_artifacts/generic/docker/docker-images.json"
    [[ "$(grep -c . "$out")" == "2" ]]
    ! grep -q 'sha256__' "$out"
    ! grep -q 'sha256:' "$out"
    grep -q '"package_name":"aerospike-server"' "$out"
    grep -q '"package_name":"absctl"' "$out"
}

@test "other package types and rows missing required fields are omitted" {
    _require_bash4_for_detect_types
    local wd root out
    wd=$(_new_artifacts_wd filter)
    root="$wd/build-artifacts"
    mkdir -p "$root"
    cat >"$root/release-bundle-record.json" <<'EOF'
{
  "artifacts": [
    {
      "path": "artifacts/maven/com/example/lib/1.0.0/lib-1.0.0.jar",
      "package_type": "maven",
      "package_name": "lib",
      "package_version": "1.0.0",
      "source_repository_key": "database-maven-dev-local"
    },
    {
      "path": "artifacts/debian/pool/absctl.deb",
      "package_type": "debian",
      "package_name": "absctl",
      "package_version": "1.2.0",
      "source_repository_key": "database-deb-dev-local"
    },
    {
      "package_type": "docker",
      "package_version": "1.0.0",
      "source_repository_key": "database-docker-dev-local"
    },
    {
      "package_type": "docker",
      "package_name": "",
      "package_version": "1.0.0",
      "source_repository_key": "database-docker-dev-local"
    },
    {
      "package_type": "oci",
      "package_name": "absctl",
      "source_repository_key": "database-oci-dev-local"
    },
    {
      "package_type": "oci",
      "package_name": "absctl",
      "package_version": "",
      "source_repository_key": "database-oci-dev-local"
    },
    {
      "package_type": "docker",
      "package_name": "aerospike-server",
      "package_version": "8.1.0.0",
      "source_repository_key": ""
    },
    {
      "package_type": "oci",
      "package_name": "aerospike-backup-service",
      "package_version": "3.7.0_20260929T140341Z"
    },
    {
      "path": "artifacts/oci/absctl/1.2.0_20260929T144224Z/list.manifest.json",
      "package_type": "oci",
      "package_name": "absctl",
      "package_version": "1.2.0_20260929T144224Z",
      "source_repository_key": "database-oci-dev-local"
    }
  ]
}
EOF

    (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)

    out="$wd/structured_build_artifacts/generic/docker/docker-images.json"
    [[ -f $out ]]
    [[ "$(cat "$out")" == '{"package_name":"absctl","package_version":"1.2.0_20260929T144224Z","source_repository_key":"database-oci-dev-local"}' ]]
}

@test "record with no docker or oci tags does not create docker-images.json" {
    _require_bash4_for_detect_types
    local wd root out
    wd=$(_new_artifacts_wd no-tags)
    root="$wd/build-artifacts"
    _plant_container_files "$root"
    cat >"$root/release-bundle-record.json" <<'EOF'
{
  "artifacts": [
    {
      "package_type": "maven",
      "package_name": "lib",
      "package_version": "1.0.0",
      "source_repository_key": "database-maven-dev-local"
    },
    {
      "package_type": "docker",
      "package_name": "aerospike-server",
      "package_version": "sha256__aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "source_repository_key": "database-docker-dev-local"
    },
    {
      "package_type": "oci",
      "package_name": "absctl",
      "package_version": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "source_repository_key": "database-oci-dev-local"
    }
  ]
}
EOF

    (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)

    out="$wd/structured_build_artifacts/generic/docker/docker-images.json"
    [[ ! -e $out ]]
    ! grep -q 'docker-images.json' "$wd/structured_build_artifacts/.manifest"
}

@test "pre-written docker-images.json is staged when no release-bundle-record.json" {
    _require_bash4_for_detect_types
    local wd root out expected
    wd=$(_new_artifacts_wd prewritten)
    root="$wd/build-artifacts"
    _plant_container_files "$root"
    expected='{"package_name":"aerospike-server","package_version":"8.1.0.0","source_repository_key":"database-docker-dev-local"}'
    printf '%s\n' "$expected" >"$root/docker-images.json"

    (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)

    out="$wd/structured_build_artifacts/generic/docker/docker-images.json"
    [[ -f $out ]]
    [[ "$(cat "$out")" == "$expected" ]]
    _assert_manifest_generic "$wd/structured_build_artifacts/.manifest"
    [[ "$(find "$wd/structured_build_artifacts" -name 'docker-images.json' | wc -l | tr -d ' ')" == "1" ]]
}

@test "release-bundle-record.json wins when a pre-written docker-images.json is also present" {
    _require_bash4_for_detect_types
    local wd root out
    wd=$(_new_artifacts_wd record-wins)
    root="$wd/build-artifacts"
    _plant_container_files "$root"
    printf '%s\n' '{"package_name":"stale-image","package_version":"0.0.1","source_repository_key":"old-prefilter"}' \
        >"$root/docker-images.json"
    cat >"$root/release-bundle-record.json" <<'EOF'
{
  "artifacts": [
    {
      "path": "artifacts/docker/aerospike-server/8.1.0.0/list.manifest.json",
      "package_type": "docker",
      "package_name": "aerospike-server",
      "package_version": "8.1.0.0",
      "source_repository_key": "database-docker-dev-local"
    },
    {
      "path": "artifacts/oci/absctl/1.2.0_20260929T144224Z/list.manifest.json",
      "package_type": "oci",
      "package_name": "absctl",
      "package_version": "1.2.0_20260929T144224Z",
      "source_repository_key": "database-oci-dev-local"
    }
  ]
}
EOF

    (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)

    out="$wd/structured_build_artifacts/generic/docker/docker-images.json"
    [[ "$(sed -n '1p' "$out")" == '{"package_name":"aerospike-server","package_version":"8.1.0.0","source_repository_key":"database-docker-dev-local"}' ]]
    [[ "$(sed -n '2p' "$out")" == '{"package_name":"absctl","package_version":"1.2.0_20260929T144224Z","source_repository_key":"database-oci-dev-local"}' ]]
    ! grep -q 'stale-image' "$out"
    ! grep -q 'old-prefilter' "$out"
    [[ "$(find "$wd/structured_build_artifacts" -name 'docker-images.json' | wc -l | tr -d ' ')" == "1" ]]
    [[ "$(grep -c 'docker-images.json' "$wd/structured_build_artifacts/.manifest")" == "1" ]]
}
