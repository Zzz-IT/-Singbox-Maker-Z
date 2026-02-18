#!/usr/bin/env bash

_get_mem_limit() {
    local total_mem_mb
    total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')

    local mem_limit_mb=$(( total_mem_mb * 95 / 100 ))
    local reserved_mb=$(( total_mem_mb - mem_limit_mb ))

    if [[ "$reserved_mb" -lt 40 ]]; then
        mem_limit_mb=$(( total_mem_mb - 40 ))
    fi

    [[ "$mem_limit_mb" -lt 10 ]] && mem_limit_mb=10
    printf '%s' "$mem_limit_mb"
}

export -f _get_mem_limit
