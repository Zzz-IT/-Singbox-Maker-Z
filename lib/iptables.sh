#!/usr/bin/env bash

_save_iptables_rules() {
    [[ -z "${INIT_SYSTEM:-}" ]] && _detect_init_system

    mkdir -p /etc/iptables 2>/dev/null || true

    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        iptables-save > /etc/iptables/rules-save 2>/dev/null || true
        rc-update add iptables default 2>/dev/null || true
    elif [[ "$INIT_SYSTEM" == "systemd" ]]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        if command -v apt-get >/dev/null 2>&1 && ! dpkg -l 2>/dev/null | grep -q iptables-persistent; then
            _pkg_install iptables-persistent
        fi
    fi

    _success "Iptables 规则已持久化。"
}
