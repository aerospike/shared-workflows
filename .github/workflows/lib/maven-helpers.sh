#!/usr/bin/env bash
# maven-helpers.sh - Shared Maven POM coordinate helpers.
#
# Sourced by deploy-artifacts (type detection, JAR metadata, upload) so POM
# parsing stays consistent across structuring and deploy stages.
#
# This file should contain only pure helpers (no globals, no side effects on source).

# _maven_read_pom_coordinates <pom>
# Prints: artifact_id group_id version packaging module_count (space-separated on stdout).
# groupId and version fall back to <parent> when absent on <project> (child modules).
_maven_read_pom_coordinates() {
    local pom="$1"
    local artifact_id group_id version packaging module_count

    artifact_id=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='artifactId'])" "$pom" 2>/dev/null || true)
    group_id=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='groupId'])" "$pom" 2>/dev/null || true)
    if [[ -z $group_id ]]; then
        group_id=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='parent']/*[local-name()='groupId'])" "$pom" 2>/dev/null || true)
    fi
    version=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='version'])" "$pom" 2>/dev/null || true)
    if [[ -z $version ]]; then
        version=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='parent']/*[local-name()='version'])" "$pom" 2>/dev/null || true)
    fi
    packaging=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='packaging'])" "$pom" 2>/dev/null || true)
    [[ -z $packaging ]] && packaging="jar"
    module_count=$(xmllint --xpath "count(/*[local-name()='project']/*[local-name()='modules']/*[local-name()='module'])" "$pom" 2>/dev/null || echo 0)
    if [[ -z $module_count ]] || [[ ! ($module_count =~ ^[0-9]+$) ]]; then
        module_count=0
    fi

    echo "$artifact_id $group_id $version $packaging $module_count"
}
