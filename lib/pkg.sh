#!/usr/bin/env bash

_pkg_install() {
    local pkgs="$*"
    [[ -z "$pkgs" ]] && return 0

    # 默认超时 300秒 (5分钟)
    local TIMEOUT_CMD="timeout 300"
    
    # 检查 timeout 命令是否存在，不存在则清空变量，避免报错
    if ! command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD=""
    fi

    if command -v apk >/dev/null 2>&1; then
        $TIMEOUT_CMD apk add --no-cache $pkgs >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        if ! DEBIAN_FRONTEND=noninteractive $TIMEOUT_CMD apt-get install -y $pkgs >/dev/null 2>&1; then
            _info "首次直接安装失败，尝试更新索引后重试..."
            $TIMEOUT_CMD apt-get update -qq >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive $TIMEOUT_CMD apt-get install -y $pkgs >/dev/null 2>&1
        fi
    elif command -v yum >/dev/null 2>&1; then
        $TIMEOUT_CMD yum install -y $pkgs >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        $TIMEOUT_CMD dnf install -y $pkgs >/dev/null 2>&1
    else
        _error "未识别的包管理器，无法安装: $pkgs"
        return 1
    fi
}

export -f _pkg_install
