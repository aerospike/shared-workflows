#!/usr/bin/env bash
# Finds the build-info record carrying a commit, given any build in its tree.
#
# Sourced by verify-artifact.sh, which supplies jfrog, urlencode and $project, and owns the $vcs
# and $run these fill in. Both persist across calls, so a second call keeps the $run a first one
# resolved.

MAX_BUILD_DEPTH=8

# shellcheck disable=SC2154 # project is the caller's, per the contract above
build_of() { jfrog "artifactory/api/build/$(urlencode "$1")/$(urlencode "$2")?project=$project"; }
# Children are the modules of type "build", each id a fully qualified <name>/<number>. Selecting
# them by name resolves nothing for a pipeline that names them differently.
children_of() { jq -r '.buildInfo.modules[]? | select(.type == "build") | .id' <<<"$1"; }

# Matches the walk in release-evidence.py in both depth cap and order, depth first and first child
# first; diverging here makes the two halves of the action disagree about the same artifact.
# $run must come from the build the caller named or the one carrying the commit, never from a
# sibling the walk merely passed through.
descend() {
    local stack=("0 $1") seen='' entry depth id info child children=()
    while ((${#stack[@]})); do
        entry=${stack[0]}
        stack=(${stack[@]+"${stack[@]:1}"})
        depth=${entry%% *}
        id=${entry#* }
        [[ $seen == *"|$id|"* ]] && continue
        seen+="|$id|"
        info=$(build_of "${id%/*}" "${id##*/}")
        if ((depth == 0)) && [[ -z $run ]]; then
            run=$(jq -r '.buildInfo.url // empty' <<<"$info")
        fi
        vcs=$(jq -c '.buildInfo.vcs[0] // empty' <<<"$info")
        if [[ -n $vcs ]]; then
            [[ -z $run ]] && run=$(jq -r '.buildInfo.url // empty' <<<"$info")
            return 0
        fi
        ((depth >= MAX_BUILD_DEPTH)) && continue
        children=()
        while read -r child; do
            [[ -n $child && $child == */* ]] && children+=("$((depth + 1)) $child")
        done < <(children_of "$info")
        ((${#children[@]})) && stack=("${children[@]}" ${stack[@]+"${stack[@]}"})
    done
    return 1
}
