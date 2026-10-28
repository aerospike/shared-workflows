#!/usr/bin/env bash
# Serve the node start and stop requests a running test writes to a control
# directory. Each start runs a new node cloned from a node setup-aerospike-server
# created but did not start; each stop removes a node this script started. The
# request and acknowledgement format is in README.md.
set -uo pipefail

if [[ ${ENABLE_BASH_TRACE_MODE-} == "true" ]]; then
    set -x
fi

error() {
    echo "Error: $1" >&2
    exit 1
}

dir=""
prefix=aerospike
network=aerospike-net
service_port=3000
template_index=""
alternate_address=""

# Parse the options of one start request into start_ip and start_alternate_port,
# or set start_error.
parse_start_options() {
    local option
    start_ip=""
    start_alternate_port=""
    start_error=""

    for option in $1; do
        case $option in
        alternate-port=*)
            if [[ -z $alternate_address ]]; then
                start_error="$option needs the alternate-access-address input"
            elif [[ ! ${option#*=} =~ ^[1-9][0-9]*$ ]]; then
                start_error="$option is not a port"
            else
                start_alternate_port=${option#*=}
            fi
            ;;
        address=*)
            if [[ ${option#*=} =~ ^[0-9]{1,3}([.][0-9]{1,3}){3}$ ]]; then
                start_ip=${option#*=}
            else
                start_error="$option is not an IPv4 address"
            fi
            ;;
        *)
            start_error="unknown start option $option"
            ;;
        esac
    done
    [[ -z $start_error ]]
}

# Write the acknowledgement for request $1 atomically, so a reader never sees
# a partial file.
ack() {
    printf '%s\n' "$2" >"$dir/$1.tmp"
    mv "$dir/$1.tmp" "$dir/$1.ack"
}

inspect() {
    docker inspect "$template" | jq -r "$1"
}

start() {
    local id=$1 name conf address args=() run_options=() option
    if ! parse_start_options "$2"; then
        ack "$id" "error=$start_error"
        return
    fi

    while docker inspect "$prefix-$next" >/dev/null 2>&1; do
        next=$((next + 1))
    done
    name="$prefix-$next"
    next=$((next + 1))
    conf="$work/$name.conf"

    if [[ -n $start_alternate_port ]]; then
        ACCESS="        alternate-access-address $alternate_address"$'\n'"        alternate-access-port $start_alternate_port"$'\n' \
            awk -v port="$service_port" '{print} $1 == "port" && $2 == port {printf "%s", ENVIRON["ACCESS"]}' \
            "$work/template.conf" >"$conf"
    else
        cp "$work/template.conf" "$conf"
    fi
    if [[ -n $start_ip ]]; then
        run_options+=(--ip "$start_ip")
    fi

    for option in "${cmd[@]}"; do
        args+=("${option/#"$template_conf"/$conf_dir/$name.conf}")
    done

    if docker cp "$conf" "$writer:$conf_dir/$name.conf" 2>"$work/err" &&
        docker run -d --name "$name" "${run_options[@]}" "${run_args[@]}" "$image" "${args[@]}" >/dev/null 2>>"$work/err"; then
        started+="$name "
        address=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$name")
        ack "$id" "$(printf 'container=%s\naddress=%s' "$name" "$address")"
        echo "Started $name ($address) $2"
    else
        ack "$id" "error=$(tr '\n' ' ' <"$work/err")"
    fi
}

stop() {
    local id=$1 name=$2
    if [[ $started == *" $name "* ]] && docker rm -f "$name" >/dev/null; then
        started=${started/ $name / }
        ack "$id" "removed=$name"
        echo "Removed $name"
    else
        ack "$id" "error=cannot remove $name, which this helper did not start"
    fi
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        --control-dir) dir=$2 ;;
        --container-name-prefix) prefix=$2 ;;
        --network) network=$2 ;;
        --service-port) service_port=$2 ;;
        --template-node-index) template_index=$2 ;;
        --alternate-access-address) alternate_address=$2 ;;
        *) error "Unknown option: $1" ;;
        esac
        shift 2
    done

    [[ -d $dir ]] || error "control directory '$dir' does not exist"
    [[ $template_index =~ ^[1-9][0-9]*$ ]] || error "template-node-index must be a positive integer (got: '$template_index')"

    template="$prefix-$template_index"
    writer="$prefix-1"
    next=$((template_index + 1))
    started=" "
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT

    docker inspect "$template" >/dev/null 2>&1 || error "template node $template does not exist"
    [[ $(docker inspect -f '{{.State.Running}}' "$writer" 2>/dev/null) == "true" ]] ||
        error "$writer is not running; it mounts the config volume new nodes read"

    image=$(inspect '.[0].Config.Image')
    entrypoint=$(inspect '.[0].Config.Entrypoint[0] // empty')
    mapfile -t cmd < <(inspect '.[0].Config.Cmd // [] | .[]')
    template_conf=""
    for ((i = 0; i < ${#cmd[@]} - 1; i++)); do
        if [[ ${cmd[i]} == "--config-file" ]]; then
            template_conf=${cmd[i + 1]}
        fi
    done
    [[ -n $template_conf ]] || error "$template has no --config-file; it needs the per-node config of a multi-node cluster"
    conf_dir=$(dirname "$template_conf")

    run_args=(--network "$network" --ulimit nofile=15000)
    [[ -n $entrypoint ]] && run_args+=(--entrypoint "$entrypoint")
    while IFS= read -r mount; do
        run_args+=(-v "$mount")
    done < <(inspect '.[0].Mounts[] | "\(if .Type == "volume" then .Name else .Source end):\(.Destination)\(if .RW then "" else ":ro" end)"')
    while IFS= read -r host; do
        run_args+=(--add-host "$host")
    done < <(inspect '.[0].HostConfig.ExtraHosts // [] | .[]')
    while IFS= read -r variable; do
        run_args+=(-e "$variable")
    done < <(inspect '.[0].Config.Env // [] | .[]')

    docker cp "$template:$template_conf" "$work/template.conf" || error "cannot copy $template_conf from $template"
    if [[ -n $alternate_address ]] && ! awk -v port="$service_port" '$1 == "port" && $2 == port {found = 1} END {exit !found}' "$work/template.conf"; then
        error "$template_conf has no 'port $service_port' line to add the alternate access address after"
    fi

    touch "$dir/.ready"
    echo "Serving node control requests in $dir (template $template)"

    local request id action arg
    while true; do
        for request in "$dir"/*.request; do
            [[ -e $request ]] || continue
            id=$(basename "$request" .request)
            action=""
            arg=""
            read -r action arg <"$request" || true
            rm -f "$request"

            case $action in
            start) start "$id" "$arg" ;;
            stop) stop "$id" "$arg" ;;
            *) ack "$id" "error=unknown request: $action $arg" ;;
            esac
        done
        sleep 0.1
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
