#!/usr/bin/env bash

_atomic_modify_json() {
    local file="$1"
    local filter="$2"

    [[ -f "$file" ]] || return 1

    local tmp="${file}.tmp"
    if jq "$filter" "$file" >"$tmp"; then
        mv -f -- "$tmp" "$file"
    else
        rm -f -- "$tmp"
        return 1
    fi
}

_add_inbound_to_config() {
    local config="$1"
    local inbound_json="$2"

    local tag
    tag=$(echo "$inbound_json" | jq -r .tag)

    if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$config" >/dev/null 2>&1; then
        _error "Tag '$tag' 已存在。"
        return 1
    fi

    _atomic_modify_json "$config" ".inbounds += [$inbound_json]"
}
