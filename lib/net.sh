#!/usr/bin/env bash

_get_public_ip() {
    if [[ -n "${GLOBAL_SERVER_IP:-}" ]]; then
        printf '%s' "$GLOBAL_SERVER_IP"
        return 0
    fi

    local ip=""
    # [优化] 使用 --max-time 替代系统级 timeout 命令
    # 尝试 IPv4
    ip=$(curl -s4 --max-time 3 icanhazip.com 2>/dev/null || curl -s4 --max-time 3 ipinfo.io/ip 2>/dev/null || true)
    
    # 尝试 IPv6
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6 --max-time 3 icanhazip.com 2>/dev/null || curl -s6 --max-time 3 ipinfo.io/ip 2>/dev/null || true)
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
