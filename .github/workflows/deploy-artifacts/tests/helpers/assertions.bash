#!/usr/bin/env bash
# Deep validation assertion helpers for bats tests

# Source command parsers
load "$(dirname "${BASH_SOURCE[0]}")/command_parsers.bash"

# Assert that an upload command is valid
# Usage: assert_upload_command_valid "$cmd" "$expected_file" "$expected_repo" "$expected_props_str" "$expected_build_name" "$expected_build_number" "$expected_project"
assert_upload_command_valid() {
        local cmd="$1"
        local expected_file="$2"
        local expected_repo="$3"
        local expected_props_str="$4"
        local expected_build_name="$5"
        local expected_build_number="$6"
        local expected_project="$7"

        # Parse the command
        local -A parsed=()
        local parse_output
        parse_output=$(parse_jf_upload_command "$cmd")
        while IFS='=' read -r key value; do
                [[ -n $key ]] && parsed["$key"]="$value"
        done <<<"$parse_output"

        # Validate file path
        if [[ -z ${parsed[file_path]-} ]]; then
                echo "FAIL: Command missing file path: $cmd" >&2
                return 1
        fi

        # Check if file path matches expected (allowing for relative paths)
        local file_path="${parsed[file_path]}"
        if [[ $file_path != *"$expected_file"* ]] && [[ $expected_file != *"$(basename "$file_path")"* ]]; then
                echo "FAIL: File path mismatch. Expected: $expected_file, Got: $file_path" >&2
                return 1
        fi

        # Validate repository
        if [[ ${parsed[repo]-} != "$expected_repo" ]]; then
                echo "FAIL: Repository mismatch. Expected: $expected_repo, Got: ${parsed[repo]-}" >&2
                return 1
        fi

        # Validate build-name
        if [[ ${parsed[build_name]-} != "$expected_build_name" ]]; then
                echo "FAIL: Build-name mismatch. Expected: $expected_build_name, Got: ${parsed[build_name]-}" >&2
                return 1
        fi

        # Validate build-number
        if [[ ${parsed[build_number]-} != "$expected_build_number" ]]; then
                echo "FAIL: Build-number mismatch. Expected: $expected_build_number, Got: ${parsed[build_number]-}" >&2
                return 1
        fi

        # Validate project
        if [[ ${parsed[project]-} != "$expected_project" ]]; then
                echo "FAIL: Project mismatch. Expected: $expected_project, Got: ${parsed[project]-}" >&2
                return 1
        fi

        # Validate --flat=false is present
        if [[ ${parsed[flat]-} != "false" ]]; then
                echo "FAIL: --flat=false not present or incorrect" >&2
                return 1
        fi

        # Validate target-props if provided
        if [[ -n $expected_props_str ]]; then
                local -A expected_props=()
                local props_output
                props_output=$(parse_target_props "$expected_props_str")
                while IFS='=' read -r key value; do
                        [[ -n $key ]] && expected_props["$key"]="$value"
                done <<<"$props_output"

                local -A actual_props=()
                if [[ -n ${parsed[target_props]-} ]]; then
                        local actual_props_output
                        actual_props_output=$(parse_target_props "${parsed[target_props]}")
                        while IFS='=' read -r key value; do
                                [[ -n $key ]] && actual_props["$key"]="$value"
                        done <<<"$actual_props_output"
                fi

                # Check each expected prop
                for key in "${!expected_props[@]}"; do
                        if [[ ${actual_props[$key]-} != "${expected_props[$key]}" ]]; then
                                echo "FAIL: Target-prop mismatch for '$key'. Expected: ${expected_props[$key]}, Got: ${actual_props[$key]-}" >&2
                                return 1
                        fi
                done
        fi

        return 0
}

# Assert that a build command is valid
# Usage: assert_build_command_valid "$cmd" "$expected_build_name" "$expected_build_number" "$expected_project"
assert_build_command_valid() {
        local cmd="$1"
        local expected_build_name="$2"
        local expected_build_number="$3"
        local expected_project="$4"

        local -A parsed=()
        local parse_output
        parse_output=$(parse_jf_build_command "$cmd")
        while IFS='=' read -r key value; do
                [[ -n $key ]] && parsed["$key"]="$value"
        done <<<"$parse_output"

        # Validate command type
        if [[ -z ${parsed[command_type]-} ]]; then
                echo "FAIL: Invalid build command: $cmd" >&2
                return 1
        fi

        # Validate build-name
        if [[ ${parsed[build_name]-} != "$expected_build_name" ]]; then
                echo "FAIL: Build-name mismatch. Expected: $expected_build_name, Got: ${parsed[build_name]-}" >&2
                return 1
        fi

        # Validate build-number
        if [[ ${parsed[build_number]-} != "$expected_build_number" ]]; then
                echo "FAIL: Build-number mismatch. Expected: $expected_build_number, Got: ${parsed[build_number]-}" >&2
                return 1
        fi

        # Validate project
        if [[ ${parsed[project]-} != "$expected_project" ]]; then
                echo "FAIL: Project mismatch. Expected: $expected_project, Got: ${parsed[project]-}" >&2
                return 1
        fi

        return 0
}

# Assert command count matches expected
# Usage: assert_command_count "$commands" "$expected_count"
assert_command_count() {
        local commands="$1"
        local expected_count="$2"

        # Count lines
        local actual_count
        actual_count=$(echo "$commands" | wc -l)

        if [[ $actual_count -ne $expected_count ]]; then
                echo "FAIL: Command count mismatch. Expected: $expected_count, Got: $actual_count" >&2
                return 1
        fi

        return 0
}

# Assert processing message appears in output
# Usage: assert_processing_message "$output" "DEB" (or "RPM", "NUPKG")
assert_processing_message() {
        local output="$1"
        local artifact_type="$2"

        if ! echo "$output" | grep -q "Processing $artifact_type:"; then
                echo "FAIL: Processing message for $artifact_type not found in output" >&2
                return 1
        fi

        return 0
}
