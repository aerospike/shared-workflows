#!/usr/bin/env bats
#
# Upload settings for .maven-bundle-metadata.json.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_deploy-artifacts.yaml"

UPLOAD_STEP='.jobs.deploy.steps[] | select(.id == "upload-bundle-metadata")'

@test "the metadata upload includes hidden files" {
    # .maven-bundle-metadata.json is a dotfile, and upload-artifact excludes
    # those by default while still reporting success.
    local value
    value="$(yq -r "${UPLOAD_STEP} | .with.\"include-hidden-files\"" "$WORKFLOW")"
    [ "$value" = "true" ]
}

@test "the metadata upload fails when it matches no file" {
    local value
    value="$(yq -r "${UPLOAD_STEP} | .with.\"if-no-files-found\"" "$WORKFLOW")"
    [ "$value" = "error" ]
}

@test "availability follows the upload rather than the pre-upload file check" {
    # A file on disk before the upload does not mean an artifact reached the
    # run, which is what create-release-bundle goes on to download.
    local expression
    expression="$(yq -r '.jobs.deploy.outputs."bundle-metadata-available"' "$WORKFLOW")"
    [[ "$expression" == *"upload-bundle-metadata.outcome"* ]]
}
