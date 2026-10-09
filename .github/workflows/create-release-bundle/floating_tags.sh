#!/usr/bin/env bash
# docker.floating_tags values carried on included build-info records.

# Print the floating-tag property from one build-info JSON document on stdin.
# Prefers docker.floating_tags, then the env property build-collect-env records.
extract_floating_tags_from_json() {
    jq -r '
        def as_string:
            if type == "string" then .
            elif type == "array" then [ .[] | select(type == "string" and . != "") ] | join(";")
            else "" end;
        def from_object:
            if ((."docker.floating_tags" | type) == "string" or (."docker.floating_tags" | type) == "array") then
                ."docker.floating_tags" | as_string
            elif ((."buildInfo.env.DOCKER_FLOATING_TAGS" | type) == "string" or (."buildInfo.env.DOCKER_FLOATING_TAGS" | type) == "array") then
                ."buildInfo.env.DOCKER_FLOATING_TAGS" | as_string
            else "" end;
        def vals($k):
            [ .[]
                | select(.key == $k)
                | (.values // [(.value // empty)])[]
                | select(type == "string" and . != "") ];
        def from_array:
            (vals("docker.floating_tags") | select(length > 0) | join(";"))
            // (vals("buildInfo.env.DOCKER_FLOATING_TAGS") | join(";"))
            // "";
        (.buildInfo.properties // .properties // null) as $p
        | if $p == null then ""
            elif ($p | type) == "object" then $p | from_object
            elif ($p | type) == "array" then $p | from_array
            else "" end
    '
}

# Join image:tag pairs from one or more property values. First occurrence wins.
merge_floating_tag_values() {
    local combined="" part piece
    local IFS=';'
    local -a pieces
    for part in "$@"; do
        [[ -z $part ]] && continue
        read -ra pieces <<<"$part"
        for piece in "${pieces[@]}"; do
            piece="${piece#"${piece%%[![:space:]]*}"}"
            piece="${piece%"${piece##*[![:space:]]}"}"
            [[ -z $piece ]] && continue
            case ";${combined};" in
            *";${piece};"*) ;;
            *)
                if [[ -z $combined ]]; then
                    combined=$piece
                else
                    combined="${combined};${piece}"
                fi
                ;;
            esac
        done
    done
    printf '%s' "$combined"
}

# jf --properties splits on unescaped ';' and ','.
escape_jf_property_value() {
    local v=$1
    v=${v//\\/\\\\}
    v=${v//;/\\;}
    v=${v//,/\\,}
    printf '%s' "$v"
}

# Print the combined docker.floating_tags value for the builds in BUILD_ARRAY.
# CREATE_RELEASE_BUNDLE_BUILD_INFO_DIR supplies JSON fixtures for tests.
# Dry-run does not call JFrog.
collect_docker_floating_tags() {
    local combined="" value file pair name number json
    local enc_name enc_number enc_project path
    if [[ -n ${CREATE_RELEASE_BUNDLE_BUILD_INFO_DIR-} ]]; then
        for file in "${CREATE_RELEASE_BUNDLE_BUILD_INFO_DIR}"/*.json; do
            [[ -f $file ]] || continue
            value=$(extract_floating_tags_from_json <"$file")
            combined=$(merge_floating_tag_values "$combined" "$value")
        done
        printf '%s' "$combined"
        return 0
    fi
    if [[ ${DRY_RUN:-false} == "true" ]]; then
        echo "Dry-run: not querying build-info for docker.floating_tags" >&2
        return 0
    fi

    enc_project=$(jq -rn --arg v "$PROJECT" '$v|@uri')
    for pair in "${BUILD_ARRAY[@]}"; do
        pair=$(echo "$pair" | tr -d '[:space:]')
        if [[ $pair != *:* ]]; then
            error "Build pair '$pair' must be in format 'name:version'"
        fi
        name="${pair%:*}"
        number="${pair#*:}"
        enc_name=$(jq -rn --arg v "$name" '$v|@uri')
        enc_number=$(jq -rn --arg v "$number" '$v|@uri')
        path="/api/build/${enc_name}/${enc_number}?project=${enc_project}"
        echo "Reading docker floating tags from build ${name}/${number}" >&2
        if ! json=$(jf rt curl -XGET "$path" -H "Accept: application/json" --silent); then
            error "failed to read build-info ${name}/${number}"
        fi
        if printf '%s' "$json" | jq -e '(.errors? | type == "array" and length > 0)' >/dev/null 2>&1; then
            error "build-info ${name}/${number} returned an error"
        fi
        value=$(printf '%s' "$json" | extract_floating_tags_from_json)
        combined=$(merge_floating_tag_values "$combined" "$value")
    done
    printf '%s' "$combined"
}
