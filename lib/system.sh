#!/usr/bin/env bash

_check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        _error "此脚本必须以 root 权限运行。"
        exit 1
    fi
}

_detect_init_system() {
    if [[ -f /sbin/openrc-run ]] || command -v rc-service >/dev/null 2>&1; then
        export INIT_SYSTEM="openrc"
        export SERVICE_FILE="/etc/init.d/sing-box"
    elif command -v systemctl >/dev/null 2>&1; then
        if [[ -d /run/systemd/system ]] || ([[ -f /proc/1/comm ]] && grep -q systemd /proc/1/comm 2>/dev/null); then
            export INIT_SYSTEM="systemd"
            export SERVICE_FILE="/etc/systemd/system/sing-box.service"
        else
            export INIT_SYSTEM="systemd"
            export SERVICE_FILE="/etc/systemd/system/sing-box.service"
        fi
    else
        export INIT_SYSTEM="unknown"
        export SERVICE_FILE=""
    fi
}

_install_yq() {
    local YQ_BIN="/usr/local/bin/yq"
    if command -v yq >/dev/null 2>&1; then
        return 0
    fi

    _info "正在安装 yq..."
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch='amd64' ;;
        aarch64|arm64) arch='arm64' ;;
        armv7l) arch='arm' ;;
        *) _error "不支持的架构: $arch"; return 1 ;;
    esac

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$YQ_BIN" "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
    elif command -v curl >/dev/null 2>&1; then
        curl -LfsS "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" -o "$YQ_BIN"
    else
        _error "缺少 wget/curl，无法安装 yq"
        return 1
    fi

    chmod +x "$YQ_BIN"
}
