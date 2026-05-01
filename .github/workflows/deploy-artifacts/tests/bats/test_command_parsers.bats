#!/usr/bin/env bats
# Tests extract_* helpers against lines shaped like entrypoint dry-run (stderr via 2>&1):
# run() prints echo -e "${green}   $*${reset}" — leading ANSI, spaces, then jf …

load '../helpers/command_parsers'

@test "extract_upload_commands finds jf rt upload after ANSI wrapper like dry-run" {
    local line=$'\033[0;32m   jf rt upload ./app.exe test-project-generic-dev-local/p --flat=false --build-name=b --project=p\033[0m'
    local cmds
    cmds=$(extract_upload_commands "$line")
    echo "$cmds" | grep -qF "jf rt upload ./app.exe"
    echo "$cmds" | grep -qF "generic-dev-local"
}

@test "extract_upload_commands finds jf nuget push after ANSI wrapper like dry-run" {
    local line=$'\033[0;32m   jf nuget push ./pkg.nupkg -Source https://example.local/nuget\033[0m'
    local cmds
    cmds=$(extract_upload_commands "$line")
    echo "$cmds" | grep -qF "jf nuget push ./pkg.nupkg"
}

@test "extract_nuget_commands finds nupkg jf rt upload after ANSI wrapper like dry-run" {
    local line=$'\033[0;32m   jf rt upload ./Aerospike.Client.8.0.2.nupkg test-project-nuget-dev-local/A/8/8.0.2/file.nupkg --build-name=b --project=p\033[0m'
    local cmds
    cmds=$(extract_nuget_commands "$line")
    echo "$cmds" | grep -qF "jf rt upload ./Aerospike.Client.8.0.2.nupkg"
    echo "$cmds" | grep -qF "nuget-dev-local"
}

@test "extract_nuget_commands ignores jf rt upload that is not nuget repo" {
    local line="   jf rt upload ./tool.exe test-project-generic-dev-local/x --project=p"
    local cmds
    cmds=$(extract_nuget_commands "$line")
    [[ -z "$cmds" ]]
}
