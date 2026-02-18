#!/usr/bin/env bash

_get_public_ip() {
    if [[ -n "${GLOBAL_SERVER_IP:-}" ]]; then
        printf '%s' "$GLOBAL_SERVER_IP"
        return 0
    fi

    local ip=""
    ip=$(timeout 5 curl -s4 --max-time 2 icanhazip.com 2>/dev/null || timeout 5 curl -s4 --max-time 2 ipinfo.io/ip 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(timeout 5 curl -s6 --max-time 2 icanhazip.com 2>/dev/null || timeout 5 curl -s6 --max-time 2 ipinfo.io/ip 2>/dev/null || true)
    fi

    export GLOBAL_SERVER_IP="$ip"
    printf '%s' "$ip"
}

_init_server_ip() {
    export server_ip
    server_ip="$(_get_public_ip)"
}

_check_port_occupied() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -q ":${port} "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep -q ":${port} "
    else
        false
    fi
}

export -f _check_port_occupied
