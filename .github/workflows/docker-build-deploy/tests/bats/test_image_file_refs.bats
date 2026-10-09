#!/usr/bin/env bats
# Which pushed refs are written to the build-info image file.

SCRIPT="${BATS_TEST_DIRNAME}/../../image_file_refs.sh"
WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"
REG="artifact.aerospike.io/connect-docker-dev-local/aerospike-graph-service"
DIGEST="sha256:indexdigestindexdigestindexdigestindexdigestindexdigest12"

@test "default tags for app version 3.3.2 record the timestamped tag and 3.3.2" {
    run "$SCRIPT" image-file --digest "$DIGEST" -- \
        "${REG}:3.3.2_20261007T212412Z" \
        "${REG}:3.3.2"
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' <<<"$output")" = "${REG}:3.3.2_20261007T212412Z@${DIGEST}" ]
    [ "$(sed -n '2p' <<<"$output")" = "${REG}:3.3.2@${DIGEST}" ]
    [ "$(grep -c . <<<"$output")" -eq 2 ]
}

@test "versions-override 3.3.2-slim records the timestamped slim tag and 3.3.2-slim" {
    run "$SCRIPT" image-file --digest "$DIGEST" -- \
        "${REG}:3.3.2-slim_20261007T212412Z" \
        "${REG}:3.3.2-slim"
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' <<<"$output")" = "${REG}:3.3.2-slim_20261007T212412Z@${DIGEST}" ]
    [ "$(sed -n '2p' <<<"$output")" = "${REG}:3.3.2-slim@${DIGEST}" ]
    [ "$(grep -c . <<<"$output")" -eq 2 ]
}

@test "latest and latest-slim are omitted from the image file" {
    # Tag generation still pushes a caller-supplied floating tag. The image file drops it.
    run "$SCRIPT" image-file --digest "$DIGEST" -- \
        "${REG}:3.3.2_20261007T212412Z" \
        "${REG}:3.3.2" \
        "${REG}:latest" \
        "${REG}:latest-slim"
    [ "$status" -eq 0 ]
    [ "$(grep -c . <<<"$output")" -eq 2 ]
    ! grep -q 'latest' <<<"$output"
}

@test "digest tags are never written" {
    run "$SCRIPT" image-file --digest "$DIGEST" -- \
        "${REG}:3.3.2" \
        "${REG}@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
        "sha256__dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    [ "$status" -eq 0 ]
    [ "$output" = "${REG}:3.3.2@${DIGEST}" ]
}

@test "the mutable version is assumed by stripping the immutable timestamp" {
    run "$SCRIPT" image-file --digest "$DIGEST" -- \
        "${REG}:3.3.2_20261007T212412Z"
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' <<<"$output")" = "${REG}:3.3.2_20261007T212412Z@${DIGEST}" ]
    [ "$(sed -n '2p' <<<"$output")" = "${REG}:3.3.2@${DIGEST}" ]
    [ "$(grep -c . <<<"$output")" -eq 2 ]

    run "$SCRIPT" image-file --digest "$DIGEST" -- \
        "${REG}:3.3.2-slim_20261007T212412Z" \
        "${REG}:dev"
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' <<<"$output")" = "${REG}:3.3.2-slim_20261007T212412Z@${DIGEST}" ]
    [ "$(sed -n '2p' <<<"$output")" = "${REG}:3.3.2-slim@${DIGEST}" ]
    [ "$(sed -n '3p' <<<"$output")" = "${REG}:dev@${DIGEST}" ]
}

@test "a version tag does not declare latest; an explicit floating tag does" {
    run "$SCRIPT" floating-property --image-name aerospike-graph-service -- \
        "${REG}:3.3.2_20261007T212412Z" \
        "${REG}:3.3.2"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run "$SCRIPT" floating-property --image-name aerospike-graph-service -- \
        "${REG}:3.3.2-slim_20261007T212412Z" \
        "${REG}:3.3.2-slim"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run "$SCRIPT" floating-property --image-name aerospike-graph-service -- \
        "${REG}:3.3.2_20261007T212412Z" \
        "${REG}:latest" \
        "${REG}:latest-slim"
    [ "$status" -eq 0 ]
    [ "$output" = "aerospike-graph-service:latest;aerospike-graph-service:latest-slim" ]
}

@test "an explicit extra tag is kept and does not become a floating tag" {
    run "$SCRIPT" floating-property --image-name aerospike-graph-service -- \
        "${REG}:3.3.2_20261007T212412Z" \
        "${REG}:dev"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "imagetools still applies every computed tag, including a caller-supplied latest" {
    grep -Fq 'docker buildx imagetools create "${tag_args[@]}" "${src_args[@]}"' "$WORKFLOW"
    grep -q "IFS=',' read -ra TAGS_ARR" "$WORKFLOW"
    grep -q 'image_file_refs.sh' "$WORKFLOW"
}
