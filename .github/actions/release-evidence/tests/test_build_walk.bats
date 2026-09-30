#!/usr/bin/env bats
# Tests for the build-info tree walk that resolves a commit.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/release-evidence"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
    project="database"
    vcs=''
    run=''

    urlencode() { printf '%s' "$1"; }
    jfrog() {
        local id=${1#artifactory/api/build/}
        id=${id%%\?*}
        local file="$TEST_TMPDIR/${id//\//__}.json"
        if [[ -f $file ]]; then cat "$file"; else echo '{}'; fi
    }

    # shellcheck source=/dev/null
    source "$ACTION_DIR/build-walk.sh"
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# build <name/number> <revision-or-empty> <run-url-or-empty> [child-id ...]
build() {
    local id=$1 revision=$2 url=$3
    shift 3
    local modules='[]'
    if (($#)); then
        modules=$(printf '%s\n' "$@" | jq -R '{type: "build", id: .}' | jq -sc .)
    fi
    local vcs_block='[]'
    if [[ -n $revision ]]; then
        vcs_block=$(jq -nc --arg r "$revision" '[{revision: $r, url: "https://github.com/a/b"}]')
    fi
    jq -nc --argjson m "$modules" --argjson v "$vcs_block" --arg u "$url" \
        '{buildInfo: {modules: $m, vcs: $v, url: $u}}' >"$TEST_TMPDIR/${id//\//__}.json"
}

@test "a build carrying its own commit resolves without descending" {
    build "top/1" "aaa111" "https://run/top"
    descend "top/1"
    [ "$(jq -r .revision <<<"$vcs")" = "aaa111" ]
}

@test "a child whose name follows no convention is still found" {
    build "top/1" "" "https://run/top" "top/1-metadata-el8-x86_64"
    build "top/1-metadata-el8-x86_64" "bbb222" "https://run/child"
    descend "top/1"
    [ "$(jq -r .revision <<<"$vcs")" = "bbb222" ]
}

@test "a child carrying another build name is reached" {
    build "top/1" "" "https://run/top" "other-build/7"
    build "other-build/7" "ccc333" "https://run/other"
    descend "top/1"
    [ "$(jq -r .revision <<<"$vcs")" = "ccc333" ]
}

@test "the walk descends past the first level" {
    build "top/1" "" "https://run/top" "mid/2"
    build "mid/2" "" "https://run/mid" "leaf/3"
    build "leaf/3" "ddd444" "https://run/leaf"
    descend "top/1"
    [ "$(jq -r .revision <<<"$vcs")" = "ddd444" ]
}

@test "a sibling without a commit does not end the search" {
    build "top/1" "" "https://run/top" "empty/2" "holder/3"
    build "empty/2" "" "https://run/empty"
    build "holder/3" "eee555" "https://run/holder"
    descend "top/1"
    [ "$(jq -r .revision <<<"$vcs")" = "eee555" ]
}

@test "the first branch is exhausted before the second is tried" {
    build "top/1" "" "https://run/top" "first/2" "second/3"
    build "first/2" "" "https://run/first" "deep/4"
    build "deep/4" "from-first" "https://run/deep"
    build "second/3" "from-second" "https://run/second"
    descend "top/1"
    [ "$(jq -r .revision <<<"$vcs")" = "from-first" ]
}

@test "a cycle terminates" {
    build "top/1" "" "https://run/top" "mid/2"
    build "mid/2" "" "https://run/mid" "top/1"
    run descend "top/1"
    [ "$status" -eq 1 ]
}

@test "a tree deeper than the cap stops rather than walking forever" {
    build "top/0" "" "https://run/top" "top/1"
    for i in $(seq 1 12); do
        build "top/$i" "" "" "top/$((i + 1))"
    done
    build "top/13" "fff666" ""
    run descend "top/0"
    [ "$status" -eq 1 ]
}

@test "a tree with no commit anywhere reports none" {
    build "top/1" "" "https://run/top" "mid/2"
    build "mid/2" "" "https://run/mid"
    run descend "top/1"
    [ "$status" -eq 1 ]
}

@test "a module id naming no build number is skipped" {
    build "top/1" "" "https://run/top" "malformed" "holder/2"
    build "holder/2" "ggg777" "https://run/holder"
    descend "top/1"
    [ "$(jq -r .revision <<<"$vcs")" = "ggg777" ]
}

@test "the run url comes from the build the caller named" {
    build "top/1" "" "https://run/top" "leaf/2"
    build "leaf/2" "hhh888" "https://run/leaf"
    descend "top/1"
    [ "$run" = "https://run/top" ]
}

@test "the run url falls back to the build carrying the commit" {
    build "top/1" "" "" "leaf/2"
    build "leaf/2" "iii999" "https://run/leaf"
    descend "top/1"
    [ "$run" = "https://run/leaf" ]
}

@test "a sibling the walk passed through never supplies the run url" {
    build "top/1" "" "" "sibling/2" "holder/3"
    build "sibling/2" "" "https://run/sibling"
    build "holder/3" "jjj000" "https://run/holder"
    descend "top/1"
    [ "$(jq -r .revision <<<"$vcs")" = "jjj000" ]
    [ "$run" = "https://run/holder" ]
}

@test "a second call keeps the run url the first one resolved" {
    build "own/1" "" "https://run/own"
    build "root/2" "kkk111" "https://run/root"
    run descend "own/1"
    [ "$status" -eq 1 ]
    descend "own/1" || true
    descend "root/2"
    [ "$(jq -r .revision <<<"$vcs")" = "kkk111" ]
    [ "$run" = "https://run/own" ]
}

@test "a failed walk still reports the run url of the build the caller named" {
    build "top/1" "" "https://run/top" "mid/2"
    build "mid/2" "" "https://run/mid"
    descend "top/1" || true
    [ "$run" = "https://run/top" ]
}
