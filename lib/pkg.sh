#!/usr/bin/env bash

_pkg_install() {
    local pkgs="$*"
    [[ -z "$pkgs" ]] && return 0

    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache $pkgs >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1; then
            _info "首次直接安装失败，尝试更新索引后重试..."
            apt-get update -qq >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1
        fi
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $pkgs >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $pkgs >/dev/null 2>&1
    else
        _error "未识别的包管理器，无法安装: $pkgs"
        return 1
    fi
}

export -f _pkg_install
