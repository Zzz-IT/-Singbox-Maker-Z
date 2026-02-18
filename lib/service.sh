#!/usr/bin/env bash

_manage_service() {
    local action="$1"
    [[ -z "${INIT_SYSTEM:-}" ]] && _detect_init_system

    [[ "$action" == "status" ]] || _info "正在使用 ${INIT_SYSTEM} 执行: ${action}..."

    case "$INIT_SYSTEM" in
        systemd)
            if [[ "$action" == "status" ]]; then
                systemctl status sing-box --no-pager -l
                return 0
            fi
            systemctl "$action" sing-box
            ;;
        openrc)
            if [[ "$action" == "status" ]]; then
                rc-service sing-box status
                return 0
            fi
            rc-service sing-box "$action"
            ;;
        *)
            _error "不支持的服务管理系统"
            return 1
            ;;
    esac

    [[ "$action" != "status" ]] && _success "sing-box 服务已 ${action}"
}

export -f _manage_service
