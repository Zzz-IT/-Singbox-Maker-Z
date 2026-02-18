#!/usr/bin/env bash

# 基础路径定义
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# 运行时目录（脚本安装目录）
INSTALL_DIR_DEFAULT="/usr/local/share/singbox-maker-z"

# 业务数据目录
SINGBOX_DIR="/usr/local/etc/sing-box"

# 线上仓库配置
GITHUB_RAW_BASE="https://raw.githubusercontent.com/Zzz-IT/-Singbox-Maker-Z/main"
INSTALL_SCRIPT_URL="${GITHUB_RAW_BASE}/install.sh"

# --- 核心组件自动补全函数 ---
_download_missing_component() {
    local name="$1"
    local target="$2"
    printf '%s\n' "检测到缺失核心组件: ${name}，正在尝试自动补全..." >&2
    if command -v curl >/dev/null 2>&1; then
        curl -LfSs "${GITHUB_RAW_BASE}/${name}" -o "${target}"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${target}" "${GITHUB_RAW_BASE}/${name}"
    else
        printf '%s\n' "错误: 未找到 curl 或 wget，无法自动补全缺失组件。" >&2
        exit 1
    fi
    [[ -f "${target}" ]] && chmod +x "${target}"
}

# --- 引入工具库 ---
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/utils.sh"
elif [[ -f "${INSTALL_DIR_DEFAULT}/utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${INSTALL_DIR_DEFAULT}/utils.sh"
else
    mkdir -p "${INSTALL_DIR_DEFAULT}"
    _download_missing_component "utils.sh" "${INSTALL_DIR_DEFAULT}/utils.sh"
    # shellcheck source=/dev/null
    source "${INSTALL_DIR_DEFAULT}/utils.sh"
fi

# 文件路径常量
SINGBOX_BIN="/usr/local/bin/sing-box"
CONFIG_FILE="${SINGBOX_DIR}/config.json"
CLASH_YAML_FILE="${SINGBOX_DIR}/clash.yaml"
METADATA_FILE="${SINGBOX_DIR}/metadata.json"
YQ_BINARY="/usr/local/bin/yq"
LOG_FILE="/var/log/sing-box.log"

# Argo Tunnel 相关常量
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
ARGO_METADATA_FILE="${SINGBOX_DIR}/argo_metadata.json"

# 全局状态
server_ip=""
INIT_SYSTEM=""
SERVICE_FILE=""
QUICK_DEPLOY_MODE=false

# 脚本全路径与 PID
SELF_SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
PID_FILE="/var/run/singbox_manager.pid"

# 脚本版本
SCRIPT_VERSION="14-Final-Robust"

# 退出清理
_cleanup_tmp() {
    rm -f -- /tmp/singbox_links.tmp 2>/dev/null || true
    rm -f -- "${SINGBOX_DIR}"/*.tmp 2>/dev/null || true
    rmdir "/tmp/singbox_cron.lock" 2>/dev/null || true
}
trap _cleanup_tmp EXIT

# --- Tag 净化函数 ---
_sanitize_tag() {
    local raw_name="$1"
    local clean_name=$(echo "$raw_name" | tr ' ' '_')
    clean_name=$(echo "$clean_name" | tr -cd '[:alnum:]_\-\u4e00-\u9fa5')
    if [ -z "$clean_name" ]; then echo "node_$(date +%s)"; else echo "$clean_name"; fi
}

# --- Crontab 锁机制 ---
_cron_lock() {
    local lock="/tmp/singbox_cron.lock"
    local i=0
    while ! mkdir "$lock" 2>/dev/null; do
        [ $i -gt 20 ] && break
        sleep 0.1
        ((i++))
    done
}
_cron_unlock() {
    rmdir "/tmp/singbox_cron.lock" 2>/dev/null || true
}

# 依赖安装
_install_dependencies() {
    local pkgs="curl jq openssl wget procps iptables socat tar iproute2"
    if command -v apk &>/dev/null; then
        pkgs="$pkgs dcron"
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        pkgs="$pkgs cronie"
    else
        pkgs="$pkgs cron"
    fi

    local needs_install=false
    for pkg in $pkgs; do
        if [[ "$pkg" == *"cron"* ]]; then
            if ! command -v crontab &>/dev/null; then needs_install=true; break; fi
        else
            if ! command -v $pkg &>/dev/null && ! dpkg -l $pkg &>/dev/null 2>&1 && ! apk info -e $pkg &>/dev/null 2>&1; then
                needs_install=true; break
            fi
        fi
    done

    if [ "$needs_install" = true ]; then 
        _info "正在预装依赖..."
        _pkg_install $pkgs
        if [ "$INIT_SYSTEM" == "systemd" ]; then
            systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null
            systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null
        elif [ "$INIT_SYSTEM" == "openrc" ]; then
            rc-update add crond default 2>/dev/null; rc-service crond start 2>/dev/null
        fi
    fi
    _install_yq
}

_set_beijing_timezone() {
    if date | grep -q "CST"; then return; fi
    _info "检测到时区非北京时间，正在自动修正..."
    if [ -f /etc/alpine-release ]; then
        ! apk info -e tzdata >/dev/null 2>&1 && apk add --no-cache tzdata >/dev/null 2>&1
        cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
    elif command -v timedatectl &>/dev/null; then
        timedatectl set-timezone Asia/Shanghai
    else
        if [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
            rm -f /etc/localtime
            ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
            echo "Asia/Shanghai" > /etc/timezone
        fi
    fi
}

_install_sing_box() {
    _info "正在安装 sing-box..."
    local arch=$(uname -m)
    local arch_tag
    case $arch in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='armv7' ;;
        *) _error "不支持的架构：$arch"; exit 1 ;;
    esac
    local api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local download_url=$(curl -s "$api_url" | jq -r ".assets[] | select(.name | contains(\"linux-${arch_tag}.tar.gz\")) | .browser_download_url")
    [ -z "$download_url" ] && { _error "无法获取下载链接"; exit 1; }
    wget -qO sing-box.tar.gz "$download_url" || { _error "下载失败"; exit 1; }
    local temp_dir=$(mktemp -d)
    tar -xzf sing-box.tar.gz -C "$temp_dir"
    mv "$temp_dir/sing-box-"*"/sing-box" ${SINGBOX_BIN}
    rm -rf sing-box.tar.gz "$temp_dir"
    chmod +x ${SINGBOX_BIN}
    _success "sing-box 安装成功"
}

_install_cloudflared() {
    [ -f "${CLOUDFLARED_BIN}" ] && return 0
    _info "正在安装 cloudflared..."
    local arch=$(uname -m); local arch_tag
    case $arch in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='arm' ;;
        *) _error "不支持的架构"; return 1 ;;
    esac
    wget -qO "${CLOUDFLARED_BIN}" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch_tag}" || { _error "下载失败"; return 1; }
    chmod +x "${CLOUDFLARED_BIN}"
    _success "cloudflared 安装成功"
}

# --- Argo Tunnel 功能 ---
_start_argo_tunnel() {
    local target_port="$1"; local protocol="$2"; local token="$3" 
    local pid_file="/tmp/singbox_argo_${target_port}.pid"
    local log_file="/tmp/singbox_argo_${target_port}.log"
    
    _info "正在启动 Argo 隧道 (端口: $target_port)..." >&2
    rm -f "${log_file}"

    if [ -n "$token" ]; then
        # 固定隧道：丢弃日志，防止OOM
        nohup ${CLOUDFLARED_BIN} tunnel run --token "$token" --logfile /dev/null > /dev/null 2>&1 &
        local cf_pid=$!; echo "$cf_pid" > "${pid_file}"; sleep 5
        if ! kill -0 "$cf_pid" 2>/dev/null; then _error "启动失败" >&2; return 1; fi
        _success "Argo 固定隧道启动成功" >&2; return 0
    else
        # 临时隧道：抓取域名
        nohup ${CLOUDFLARED_BIN} tunnel --url "http://localhost:${target_port}" --logfile "${log_file}" > /dev/null 2>&1 &
        local cf_pid=$!; echo "$cf_pid" > "${pid_file}"
        local tunnel_domain=""; local wait_count=0
        while [ $wait_count -lt 30 ]; do
            sleep 2; wait_count=$((wait_count + 2))
            if ! kill -0 "$cf_pid" 2>/dev/null; then return 1; fi
            if [ -f "${log_file}" ]; then
                tunnel_domain=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "${log_file}" 2>/dev/null | tail -1 | sed 's|https://||')
                if [ -n "$tunnel_domain" ]; then 
                    : > "${log_file}" # 抓取成功后立即清空日志
                    break 
                fi
            fi
        done
        if [ -n "$tunnel_domain" ]; then echo "$tunnel_domain"; return 0; else return 1; fi
    fi
}

_stop_argo_tunnel() {
    local target_port="$1"; [ -z "$target_port" ] && return
    local pid_file="/tmp/singbox_argo_${target_port}.pid"
    if [ -f "$pid_file" ]; then kill $(cat "$pid_file") 2>/dev/null; rm -f "$pid_file" "/tmp/singbox_argo_${target_port}.log"; fi
}

_stop_all_argo_tunnels() {
    for pid_file in /tmp/singbox_argo_*.pid; do
        [ -e "$pid_file" ] || continue
        local port=${pid_file#*argo_}; port=${port%.pid}; _stop_argo_tunnel "$port"
    done
    pkill -f "cloudflared" 2>/dev/null
}

# ... (Argo配置函数保留原样，省略以节省篇幅，功能逻辑未变) ...
_add_argo_vless_ws() {
    # (此部分与原代码一致)
    _info " 创建 VLESS-WS + Argo 隧道节点 "
    _install_cloudflared || return 1
    read -p "请输入 Argo 内部监听端口 (回车随机生成): " input_port
    local port="$input_port"
    if [[ -z "$port" ]] || [[ ! "$port" =~ ^[0-9]+$ ]]; then port=$(shuf -i 10000-60000 -n 1); fi
    read -p "请输入 WebSocket 路径 (回车随机生成): " ws_path
    [ -z "$ws_path" ] && ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
    [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
    echo "请选择隧道模式: 1.临时 2.固定(Token)"
    read -p "选择 [1/2] (默认: 1): " mode; mode=${mode:-1}
    local token=""; local domain=""; local type="temp"
    if [ "$mode" == "2" ]; then
        type="fixed"
        read -p "请粘贴 Token: " input_token
        token=$(echo "$input_token" | grep -oE 'ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' | head -1)
        [ -z "$token" ] && token=$(echo "$input_token" | grep -oE 'ey[A-Za-z0-9_-]{20,}' | head -1)
        [ -z "$token" ] && token="$input_token"
        if [ -z "$token" ]; then _error "Token 无效"; return 1; fi
        read -p "请输入绑定的域名: " domain; [ -z "$domain" ] && return 1
    fi
    local name="Argo-Vless"; read -p "节点名称 (默认: $name): " n; name=${n:-$name}
    local tag="argo_vless_${port}_$(_sanitize_tag "$name")"; local uuid=$(${SINGBOX_BIN} generate uuid)
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$uuid" --arg w "$ws_path" '{"type":"vless","tag":$t,"listen":"127.0.0.1","listen_port":($p|tonumber),"users":[{"uuid":$u,"flow":""}],"transport":{"type":"ws","path":$w}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound]" || return 1
    _manage_service "restart"; sleep 2
    if [ "$type" == "fixed" ]; then _start_argo_tunnel "$port" "vless-ws" "$token" || return 1
    else domain=$(_start_argo_tunnel "$port" "vless-ws"); [ -z "$domain" ] && return 1; fi
    local meta=$(jq -n --arg t "$tag" --arg n "$name" --arg d "$domain" --arg p "$port" --arg u "$uuid" --arg w "$ws_path" --arg ty "$type" --arg tok "$token" '{($t):{name:$n,domain:$d,local_port:($p|tonumber),uuid:$u,path:$w,protocol:"vless-ws",type:$ty,token:$tok}}')
    [ ! -f "$ARGO_METADATA_FILE" ] && echo '{}' > "$ARGO_METADATA_FILE"
    _atomic_modify_json "$ARGO_METADATA_FILE" ". + $meta"
    local proxy=$(jq -n --arg n "$name" --arg s "$domain" --arg u "$uuid" --arg w "$ws_path" '{"name":$n,"type":"vless","server":$s,"port":443,"uuid":$u,"tls":true,"network":"ws","servername":$s,"ws-opts":{"path":$w,"headers":{"Host":$s}}}')
    _add_node_to_yaml "$proxy"; _enable_argo_watchdog; _success "Argo 节点创建成功！"
}

_add_argo_trojan_ws() {
    # (此部分与原代码一致)
    _info " 创建 Trojan-WS + Argo 隧道节点 "
    _install_cloudflared || return 1
    read -p "请输入 Argo 内部监听端口 (回车随机生成): " input_port
    local port="$input_port"
    if [[ -z "$port" ]] || [[ ! "$port" =~ ^[0-9]+$ ]]; then port=$(shuf -i 10000-60000 -n 1); fi
    read -p "请输入 WebSocket 路径: " ws_path; [ -z "$ws_path" ] && ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
    [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
    read -p "请输入密码 (回车随机): " password; [ -z "$password" ] && password=$(${SINGBOX_BIN} generate rand --hex 16)
    echo "请选择隧道模式: 1.临时 2.固定(Token)"
    read -p "选择 [1/2] (默认: 1): " mode; mode=${mode:-1}
    local token=""; local domain=""; local type="temp"
    if [ "$mode" == "2" ]; then
        type="fixed"
        read -p "请粘贴 Token: " input_token
        token=$(echo "$input_token" | grep -oE 'ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' | head -1)
        [ -z "$token" ] && token=$(echo "$input_token" | grep -oE 'ey[A-Za-z0-9_-]{20,}' | head -1)
        [ -z "$token" ] && token="$input_token"
        if [ -z "$token" ]; then _error "Token 无效"; return 1; fi
        read -p "请输入绑定的域名: " domain; [ -z "$domain" ] && return 1
    fi
    local name="Argo-Trojan"; read -p "节点名称 (默认: $name): " n; name=${n:-$name}
    local tag="argo_trojan_${port}_$(_sanitize_tag "$name")"
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$password" --arg w "$ws_path" '{"type":"trojan","tag":$t,"listen":"127.0.0.1","listen_port":($p|tonumber),"users":[{"password":$pw}],"transport":{"type":"ws","path":$w}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound]" || return 1
    _manage_service "restart"; sleep 2
    if [ "$type" == "fixed" ]; then _start_argo_tunnel "$port" "trojan-ws" "$token" || return 1
    else domain=$(_start_argo_tunnel "$port" "trojan-ws"); [ -z "$domain" ] && return 1; fi
    local meta=$(jq -n --arg t "$tag" --arg n "$name" --arg d "$domain" --arg p "$port" --arg pw "$password" --arg w "$ws_path" --arg ty "$type" --arg tok "$token" '{($t):{name:$n,domain:$d,local_port:($p|tonumber),password:$pw,path:$w,protocol:"trojan-ws",type:$ty,token:$tok}}')
    [ ! -f "$ARGO_METADATA_FILE" ] && echo '{}' > "$ARGO_METADATA_FILE"
    _atomic_modify_json "$ARGO_METADATA_FILE" ". + $meta"
    local proxy=$(jq -n --arg n "$name" --arg s "$domain" --arg pw "$password" --arg w "$ws_path" '{"name":$n,"type":"trojan","server":$s,"port":443,"password":$pw,"tls":true,"network":"ws","sni":$s,"ws-opts":{"path":$w,"headers":{"Host":$s}}}')
    _add_node_to_yaml "$proxy"; _enable_argo_watchdog; _success "Argo 节点创建成功！"
}

_view_argo_nodes() {
    _info "Argo 节点列表"
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then _warning "无节点"; return; fi
    jq -r 'to_entries[] | "\(.value.name)|\(.value.type)|\(.value.protocol)|\(.value.local_port)|\(.value.domain)"' "$ARGO_METADATA_FILE" | \
    while IFS='|' read -r name type protocol port domain; do
        echo -e "节点: ${GREEN}${name}${NC} | ${protocol} | Port:${port}"
        local pid_file="/tmp/singbox_argo_${port}.pid"
        if [ -f "$pid_file" ] && kill -0 $(cat "$pid_file") 2>/dev/null; then
             echo -e "状态: ${GREEN}运行中${NC} | 域名: ${CYAN}${domain}${NC}"
        else
             echo -e "状态: ${RED}已停止${NC}"
        fi
        echo "----------------------------------------"
    done
}

_delete_argo_node() {
    [ ! -f "$ARGO_METADATA_FILE" ] && return
    local i=1; local keys=(); local names=(); local ports=()
    while IFS='|' read -r key name port; do
        keys+=("$key"); names+=("$name"); ports+=("$port")
        echo -e "$i) ${name} (端口: $port)"; ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)"' "$ARGO_METADATA_FILE")
    read -p "删除编号 (0返回): " choice; [[ "$choice" == "0" || -z "$choice" ]] && return
    local idx=$((choice - 1))
    local n=${names[$idx]}; local p=${ports[$idx]}; local k=${keys[$idx]}
    _stop_argo_tunnel "$p"
    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$k\"))"
    jq "del(.\"$k\")" "$ARGO_METADATA_FILE" > "${ARGO_METADATA_FILE}.tmp" && mv "${ARGO_METADATA_FILE}.tmp" "$ARGO_METADATA_FILE"
    _remove_node_from_yaml "$n"
    _manage_service "restart"
    _success "删除成功"
}

_restart_argo_tunnel_menu() {
    [ ! -f "$ARGO_METADATA_FILE" ] && return
    local i=1; local keys=(); local ports=(); local protos=(); local types=(); local tokens=()
    while IFS='|' read -r k n p pr ty tok; do
        keys+=("$k"); ports+=("$p"); protos+=("$pr"); types+=("$ty"); tokens+=("$tok")
        echo -e "$i) $n"; ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)|\(.value.protocol)|\(.value.type)|\(.value.token)"' "$ARGO_METADATA_FILE")
    read -p "重启编号 (a全部): " c; [[ -z "$c" ]] && return
    local idxs=(); if [ "$c" == "a" ]; then for ((j=0;j<${#keys[@]};j++)); do idxs+=($j); done; else idxs+=($((c-1))); fi
    for idx in "${idxs[@]}"; do
        local p=${ports[$idx]}; local ty=${types[$idx]}; local pr=${protos[$idx]}; local tok=${tokens[$idx]}; local k=${keys[$idx]}
        _stop_argo_tunnel "$p"; sleep 1
        if [ "$ty" == "fixed" ]; then _start_argo_tunnel "$p" "$pr" "$tok"
        else local dom=$(_start_argo_tunnel "$p" "$pr"); [ -n "$dom" ] && jq ".\"$k\".domain = \"$dom\"" "$ARGO_METADATA_FILE" > "${ARGO_METADATA_FILE}.tmp" && mv "${ARGO_METADATA_FILE}.tmp" "$ARGO_METADATA_FILE"; fi
    done
    _success "重启完成"
}

_stop_argo_menu() { _stop_all_argo_tunnels; _success "已停止"; }

_argo_keepalive() {
    local lock="/tmp/singbox_keepalive.lock"; [ -f "$lock" ] && kill -0 $(cat "$lock") 2>/dev/null && return
    echo "$$" > "$lock"; trap 'rm -f "$lock"' RETURN EXIT
    [ ! -f "$ARGO_METADATA_FILE" ] && return
    local 标签=$(jq -r 'keys[]' "$ARGO_METADATA_FILE")
    for tag in $tags; do
        local port=$(jq -r ".\"$tag\".local_port" "$ARGO_METADATA_FILE")
        local type=$(jq -r ".\"$tag\".type" "$ARGO_METADATA_FILE")
        local token=$(jq -r ".\"$tag\".token // empty" "$ARGO_METADATA_FILE")
        local pid="/tmp/singbox_argo_${port}.pid"
        
        # [日志监控] 防止临时隧道日志过大
        local log_file="/tmp/singbox_argo_${port}.log"
        if [ -f "$log_file" ] && [ $(stat -c%s "$log_file" 2>/dev/null || echo 0) -gt 5242880 ]; then
            : > "$log_file"
        fi

        if [ ! -f "$pid" ] || ! kill -0 $(cat "$pid") 2>/dev/null; then
            if [ "$type" == "fixed" ]; then _start_argo_tunnel "$port" "fixed" "$token"
            else local d=$(_start_argo_tunnel "$port" "temp"); [ -n "$d" ] && _atomic_modify_json "$ARGO_METADATA_FILE" ".\"$tag\".domain = \"$d\""; fi
        fi
    done
}

_enable_argo_watchdog() { 
    _cron_lock
    local j="* * * * * bash ${SELF_SCRIPT_PATH} keepalive >/dev/null 2>&1"
    ! crontab -l 2>/dev/null | grep -Fq "$j" && (crontab -l 2>/dev/null; echo "$j") | crontab -
    _cron_unlock
}
_disable_argo_watchdog() { 
    _cron_lock
    local j="bash ${SELF_SCRIPT_PATH} keepalive"
    crontab -l 2>/dev/null | grep -Fv "$j" | crontab -
    _cron_unlock
}

_uninstall_argo() {
    _stop_all_argo_tunnels
    if [ -f "$ARGO_METADATA_FILE" ]; then
        local tags=$(jq -r 'keys[]' "$ARGO_METADATA_FILE")
        for t in $tags; do _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$t\"))"; local n=$(jq -r ".\"$t\".name" "$ARGO_METADATA_FILE"); _remove_node_from_yaml "$n"; done
    fi
    _disable_argo_watchdog; rm -f "${CLOUDFLARED_BIN}" "${ARGO_METADATA_FILE}" /tmp/singbox_argo_*; rm -rf "/etc/cloudflared"; _manage_service "restart"; _success "已卸载"
}

_argo_menu() {
    local CYAN='\033[0;36m'; local WHITE='\033[1;37m'; local GREY='\033[0;37m'; local NC='\033[0m'
    while true; do
        clear; echo -e "\n\n\n      ${CYAN}A R G O   M A N A G E R${NC}\n  ${GREY}──────────────────────────${NC}"
        echo -e "  ${WHITE}01.${NC} 部署 VLESS 隧道     ${WHITE}02.${NC} 部署 Trojan 隧道"
        echo -e "  ${WHITE}03.${NC} 查看节点            ${WHITE}04.${NC} 删除节点"
        echo -e "  ${WHITE}05.${NC} 重启服务            ${WHITE}06.${NC} 停止服务"
        echo -e "  ${WHITE}07.${NC} 卸载服务            ${WHITE}00.${NC} 退出"
        echo -e "\n"; read -e -p "  选择 > " c
        case $c in
            1|01) _add_argo_vless_ws ;; 2|02) _add_argo_trojan_ws ;; 3|03) _view_argo_nodes ;; 4|04) _delete_argo_node ;;
            5|05) _restart_argo_tunnel_menu ;; 6|06) _stop_argo_menu ;; 7|07) _uninstall_argo ;; 0|00) return ;;
        esac; read -n 1 -s -r -p "  按键继续..."
    done
}

# ... (服务管理、配置文件、节点添加函数保留，逻辑未变) ...
_create_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target
[Service]
Environment="GOMEMLIMIT=$(_get_mem_limit)MiB"
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
}
_create_openrc_service() {
    touch "${LOG_FILE}"
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="${SINGBOX_BIN}"
command_args="run -c ${CONFIG_FILE}"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
pidfile="${PID_FILE}"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
depend() { need net; after firewall; }
start_pre() { export GOMEMLIMIT="$(_get_mem_limit)MiB"; }
EOF
    chmod +x "$SERVICE_FILE"
}
_create_service_files() {
    [ -f "$SERVICE_FILE" ] && return
    if [ "$INIT_SYSTEM" == "systemd" ]; then _create_systemd_service; systemctl daemon-reload; systemctl enable sing-box
    elif [ "$INIT_SYSTEM" == "openrc" ]; then _create_openrc_service; rc-update add sing-box default; fi
}
_view_log() { if [ "$INIT_SYSTEM" == "systemd" ]; then journalctl -u sing-box -f --no-pager; else tail -f "$LOG_FILE"; fi; }
_uninstall() {
    read -p "确认卸载? (y/N): " c; [[ "$c" != "y" ]] && return
    _manage_service "stop"
    if [ "$INIT_SYSTEM" == "systemd" ]; then systemctl disable sing-box; systemctl daemon-reload; elif [ "$INIT_SYSTEM" == "openrc" ]; then rc-update del sing-box default; fi
    rm -rf "${SINGBOX_DIR}" "${LOG_FILE}" "/etc/singbox"; pkill -f "cloudflared"; rm -f "${CLOUDFLARED_BIN}" "/etc/cloudflared"
    rm -f "${SCRIPT_DIR}/utils.sh" "${SELF_SCRIPT_PATH}" "/usr/local/bin/sb"; sed -i '/sing-box/d' /etc/motd 2>/dev/null; rm -f "${SINGBOX_BIN}" "${YQ_BINARY}"
    _success "已卸载"; exit 0
}
_initialize_config_files() {
    mkdir -p ${SINGBOX_DIR}
    [ -s "$CONFIG_FILE" ] || echo '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}' > "$CONFIG_FILE"
    [ -s "$METADATA_FILE" ] || echo "{}" > "$METADATA_FILE"
    if [ ! -s "$CLASH_YAML_FILE" ]; then echo -e "port: 7890\nsocks-port: 7891\nallow-lan: false\nmode: rule\nlog-level: info\nexternal-controller: '127.0.0.1:9090'\nproxies: []\nproxy-groups: [{name: \"节点选择\", type: select, proxies: []}]\nrules: [MATCH,节点选择]" > "$CLASH_YAML_FILE"; fi
}
_cleanup_legacy_config() {
    if jq -e '.outbounds[] | select(.tag | startswith("relay-out-"))' "$CONFIG_FILE" >/dev/null 2>&1; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
        jq 'del(.outbounds[] | select(.tag | startswith("relay-out-"))) | del(.route.rules[] | select(.outbound | startswith("relay-out-")))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi
    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then jq '.outbounds = [{"type":"direct","tag":"direct"}] + .outbounds' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"; fi
    if ! jq -e '.route.final == "direct"' "$CONFIG_FILE" >/dev/null 2>&1; then jq '.route.final = "direct"' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"; fi
}
_generate_self_signed_cert() { openssl ecparam -genkey -name prime256v1 -out "$3" >/dev/null 2>&1; openssl req -new -x509 -days 3650 -key "$3" -out "$2" -subj "/CN=${1}" >/dev/null 2>&1; }
_atomic_modify_json() { cp "$1" "${1}.tmp"; if jq "$2" "${1}.tmp" > "$1"; then rm "${1}.tmp"; else mv "${1}.tmp" "$1"; return 1; fi; }
_atomic_modify_yaml() { ${YQ_BINARY} eval "$2" -i "$1"; }

_get_proxy_field() {
    local proxy_name="$1"; local field="$2"
    PROXY_NAME="$proxy_name" ${YQ_BINARY} eval '.proxies[] | select(.name == env(PROXY_NAME)) | '"$field" "${CLASH_YAML_FILE}" 2>/dev/null | head -n 1
}
_add_node_to_yaml() {
    local j="$1"; local n=$(echo "$j" | jq -r .name)
    _atomic_modify_yaml "$CLASH_YAML_FILE" ".proxies |= . + [$j] | .proxies |= unique_by(.name)"
    PROXY_NAME="$n" ${YQ_BINARY} eval '.proxy-groups[] |= (select(.name == "节点选择") | .proxies |= . + [env(PROXY_NAME)] | .proxies |= unique)' -i "$CLASH_YAML_FILE"
}
_remove_node_from_yaml() {
    local n="$1"
    PROXY_NAME="$n" ${YQ_BINARY} eval 'del(.proxies[] | select(.name == env(PROXY_NAME)))' -i "$CLASH_YAML_FILE"
    PROXY_NAME="$n" ${YQ_BINARY} eval '.proxy-groups[] |= (select(.name == "节点选择") | .proxies |= del(.[] | select(. == env(PROXY_NAME))))' -i "$CLASH_YAML_FILE"
}

_show_node_link() {
    local type="$1"; local name="$2"; local link_ip="$3"; local port="$4"; shift 4
    local url=""
    case "$type" in
        "vless-reality")
            local u="$1" sni="$2" pk="$3" sid="$4"
            url="vless://${u}@${link_ip}:${port}?security=reality&encryption=none&pbk=${pk}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${sni}&sid=${sid}#$(_url_encode "$name")" ;;
        "vless-ws-tls")
            local u="$1" sni="$2" path="$3" sv="$4"; local iparam=""; [[ "$sv" == "true" ]] && iparam="&insecure=1"
            url="vless://${u}@${link_ip}:${port}?security=tls&encryption=none&type=ws&host=${sni}&path=$(_url_encode "$path")&sni=${sni}${iparam}#$(_url_encode "$name")" ;;
        "vless-tcp") url="vless://${1}@${link_ip}:${port}?encryption=none&type=tcp#$(_url_encode "$name")" ;;
        "trojan-ws-tls")
            local p="$1" sni="$2" path="$3" sv="$4"; local iparam=""; [[ "$sv" == "true" ]] && iparam="&allowInsecure=1"
            url="trojan://${p}@${link_ip}:${port}?security=tls&type=ws&host=${sni}&path=$(_url_encode "$path")&sni=${sni}${iparam}#$(_url_encode "$name")" ;;
        "hysteria2")
            local p="$1" sni="$2" op="$3" hop="$4"; local oparam=""; [[ -n "$op" ]] && oparam="&obfs=salamander&obfs-password=${op}"; local hparam=""; [[ -n "$hop" ]] && hparam="&mport=${hop}"
            url="hysteria2://${p}@${link_ip}:${port}?sni=${sni}&insecure=1${oparam}${hparam}#$(_url_encode "$name")" ;;
        "tuic") url="tuic://${1}:${2}@${link_ip}:${port}?sni=${3}&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#$(_url_encode "$name")" ;;
        "anytls")
            local p="$1" sni="$2" sv="$3"; local iparam=""; [ "$sv" == "true" ] && iparam="&insecure=1&allowInsecure=1"
            url="anytls://${p}@${link_ip}:${port}?security=tls&sni=${sni}${iparam}&type=tcp#$(_url_encode "$name")" ;;
        "shadowsocks") url="ss://$(_url_encode "${1}:${2}")@${link_ip}:${port}#$(_url_encode "$name")" ;;
        "socks") echo -e "\n节点: $name | 用户: $1 | 密码: $2"; return ;;
    esac
    if [ -n "$url" ]; then echo -e "\n${YELLOW}--- 分享链接 ---${NC}\n${CYAN}${url}${NC}"; fi
}

# ... (节点添加函数 _add_vless_ws_tls 等省略，原逻辑保持不变) ...
_add_vless_ws_tls() {
    local camouflage_domain="" port="" is_cdn_mode=false client_server_addr="${server_ip}" name=""
    read -p "连接模式 (1.直连[默认]2.优选域名/IP): " mode_choice
    if [ "$mode_choice" == "2" ]; then is_cdn_mode=true; read -p "优选域名 (默认 www.visa.com.sg): " c; client_server_addr=${c:-"www.visa.com.sg"}; else read -p "连接地址 (默认 ${server_ip}): " c; client_server_addr=${c:-$server_ip}; fi
    [[ "$client_server_addr" == *":"* && "$client_server_addr" != "["* ]] && client_server_addr="[${client_server_addr}]"
    read -p "伪装域名: " camouflage_domain; [ -z "$camouflage_domain" ] && return 1
    read -p "监听端口: " port
    [[ -z "$port" ]] && _error "端口不能为空" && return 1
    local dn="VLESS-WS"; [ "$is_cdn_mode" == "true" ] && dn="VLESS-CDN-443"
    read -p "名称 (默认 $dn): " cn; name=${cn:-$dn}
    local safe_name=$(_sanitize_tag "$name"); local tag="${safe_name}_${port}"
    if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then tag="${tag}_$(openssl rand -hex 2)"; fi
    local client_port="$port"; [ "$is_cdn_mode" == "true" ] && client_port="443"
    read -p "WS路径 (回车随机): " w; ws_path=${w:-"/"$(${SINGBOX_BIN} generate rand --hex 8)}; [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
    local cert_path="${SINGBOX_DIR}/${tag}.pem" key_path="${SINGBOX_DIR}/${tag}.key" skip_verify=false
    read -p "证书类型 (1.自签[默认] 2.上传): " cert_choice; cert_choice=${cert_choice:-1}
    if [ "$cert_choice" == "1" ]; then _generate_self_signed_cert "$camouflage_domain" "$cert_path" "$key_path" || return 1; skip_verify=true
    else read -p "证书路径: " cert_path; read -p "私钥路径: " key_path; read -p "跳过验证? (y/N): " u; [[ "$u" == "y" ]] && skip_verify=true; fi
    local uuid=$(${SINGBOX_BIN} generate uuid)
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$uuid" --arg cp "$cert_path" --arg kp "$key_path" --arg w "$ws_path" '{"type":"vless","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"uuid":$u,"flow":""}],"tls":{"enabled":true,"certificate_path":$cp,"key_path":$kp},"transport":{"type":"ws","path":$w}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound] | .inbounds |= unique_by(.tag)" || return 1
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": {name:\"$name\", server_name:\"$camouflage_domain\"}}" || return 1
    local proxy=$(jq -n --arg n "$name" --arg s "$client_server_addr" --arg p "$client_port" --arg u "$uuid" --arg sn "$camouflage_domain" --arg w "$ws_path" --arg sv "$skip_verify" '{"name":$n,"type":"vless","server":$s,"port":($p|tonumber),"uuid":$u,"tls":true,"udp":true,"skip-cert-verify":($sv=="true"),"network":"ws","servername":$sn,"ws-opts":{"path":$w,"headers":{"Host":$sn}}}')
    _add_node_to_yaml "$proxy"; _success "VLESS-WS 节点 [${name}] 添加成功"; _show_node_link "vless-ws-tls" "$name" "$client_server_addr" "$client_port" "$uuid" "$camouflage_domain" "$ws_path" "$skip_verify"
}
# (其余添加节点函数 _add_trojan_ws_tls, _add_anytls 等均与原代码一致，需包含在文件中) ...
_add_trojan_ws_tls() {
    local camouflage_domain="" port="" is_cdn_mode=false client_server_addr="${server_ip}" name=""
    read -p "连接模式 (1.直连[默认]2.优选): " m; if [ "$m" == "2" ]; then is_cdn_mode=true; read -p "优选域名(默认 www.visa.com.sg): " c; client_server_addr=${c:-"www.visa.com.sg"}; else read -p "连接地址(默认 ${server_ip}): " c; client_server_addr=${c:-$server_ip}; fi
    read -p "伪装域名: " camouflage_domain; 
    read -p "监听端口: " port
    [[ -z "$port" ]] && _error "端口不能为空" && return 1 
    local dn="Trojan-WS"; read -p "名称 (默认 $dn): " cn; name=${cn:-$dn}
    local safe_name=$(_sanitize_tag "$name"); local tag="${safe_name}_${port}"
    if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then tag="${tag}_$(openssl rand -hex 2)"; fi
    local client_port="$port"; [ "$is_cdn_mode" == "true" ] && client_port="443"
    read -p "WS路径(回车随机): " w; ws_path=${w:-"/"$(${SINGBOX_BIN} generate rand --hex 8)}
    local cert_path="${SINGBOX_DIR}/${tag}.pem" key_path="${SINGBOX_DIR}/${tag}.key" skip_verify=false
    read -p "证书类型 (1.自签[默认] 2.上传): " cert_choice; cert_choice=${cert_choice:-1}
    if [ "$cert_choice" == "1" ]; then _generate_self_signed_cert "$camouflage_domain" "$cert_path" "$key_path" || return 1; skip_verify=true
    else read -p "证书路径: " cert_path; read -p "私钥路径: " key_path; read -p "跳过验证? (y/N): " u; [[ "$u" == "y" ]] && skip_verify=true; fi
    read -p "密码: " p; password=${p:-$(${SINGBOX_BIN} generate rand --hex 16)}
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$password" --arg cp "$cert_path" --arg kp "$key_path" --arg w "$ws_path" '{"type":"trojan","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"password":$pw}],"tls":{"enabled":true,"certificate_path":$cp,"key_path":$kp},"transport":{"type":"ws","path":$w}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound] | .inbounds |= unique_by(.tag)" || return 1
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": {name:\"$name\"}}" || return 1
    local proxy=$(jq -n --arg n "$name" --arg s "$client_server_addr" --arg p "$client_port" --arg pw "$password" --arg sn "$camouflage_domain" --arg w "$ws_path" --arg sv "$skip_verify" '{"name":$n,"type":"trojan","server":$s,"port":($p|tonumber),"password":$pw,"udp":true,"skip-cert-verify":($sv=="true"),"network":"ws","sni":$sn,"ws-opts":{"path":$w,"headers":{"Host":$s}}}')
    _add_node_to_yaml "$proxy"; _success "Trojan-WS 节点 [${name}] 添加成功"; _show_node_link "trojan-ws-tls" "$name" "$client_server_addr" "$client_port" "$password" "$camouflage_domain" "$ws_path" "$skip_verify"
}
_add_anytls() {
    local node_ip="${server_ip}" port="" server_name="www.apple.com" name=""
    read -p "监听端口: " port
    [[ -z "$port" ]] && _error "端口不能为空" && return 1
    read -p "SNI (默认 www.apple.com): " sn; server_name=${sn:-"www.apple.com"}; read -p "名称 (默认 AnyTLS): " cn; name=${cn:-"AnyTLS"}
    local safe_name=$(_sanitize_tag "$name"); local tag="${safe_name}_${port}"; if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then tag="${tag}_$(openssl rand -hex 2)"; fi
    read -p "证书类型 (1.自签[默认] 2.上传): " cert_choice; cert_choice=${cert_choice:-1}
    local cert_path="" key_path="" skip_verify=true
    if [ "$cert_choice" == "1" ]; then cert_path="${SINGBOX_DIR}/${tag}.pem"; key_path="${SINGBOX_DIR}/${tag}.key"; _generate_self_signed_cert "$server_name" "$cert_path" "$key_path" || return 1
    else read -p "证书路径: " cert_path; read -p "私钥路径: " key_path; read -p "跳过验证? (y/N): " u; [[ "$u" == "y" ]] && skip_verify=true; fi
    read -p "密码/UUID(回车随机): " p; password=${p:-$(${SINGBOX_BIN} generate uuid)}; local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$password" --arg sn "$server_name" --arg cp "$cert_path" --arg kp "$key_path" '{"type": "anytls", "tag": $t, "listen": "::", "listen_port": ($p|tonumber), "users": [{"name": "default", "password": $pw}], "padding_scheme": ["stop=2","0=100-200","1=100-200"], "tls": {"enabled": true, "server_name": $sn, "certificate_path": $cp, "key_path": $kp}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound] | .inbounds |= unique_by(.tag)" || return 1
    local proxy=$(jq -n --arg n "$name" --arg s "$node_ip" --arg p "$port" --arg pw "$password" --arg sn "$server_name" --arg sv "$skip_verify" '{"name": $n, "type": "anytls", "server": $s, "port": ($p|tonumber), "password": $pw, "client-fingerprint": "chrome", "udp": true, "idle-session-check-interval": 30, "idle-session-timeout": 30, "min-idle-session": 0, "sni": $sn, "alpn": ["h2", "http/1.1"], "skip-cert-verify": ($sv=="true")}')
    _add_node_to_yaml "$proxy"; _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": {server_name:\"$server_name\", name:\"$name\"}}" || return 1
    _success "AnyTLS 节点 [${name}] 添加成功"; _show_node_link "anytls" "$name" "$link_ip" "$port" "$password" "$server_name" "$skip_verify"
}
_add_vless_reality() {
    local node_ip="${server_ip}" port="" server_name="www.apple.com" name=""
    read -p "伪装域名 (默认 www.apple.com): " sn; server_name=${sn:-"www.apple.com"}; 
    read -p "监听端口: " port
    [[ -z "$port" ]] && _error "端口不能为空" && return 1
    read -p "名称 (默认 VLESS-REALITY): " cn; name=${cn:-"VLESS-REALITY"}
    local safe_name=$(_sanitize_tag "$name"); local tag="${safe_name}_${port}"; if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then tag="${tag}_$(openssl rand -hex 2)"; fi
    local uuid=$(${SINGBOX_BIN} generate uuid); local keypair=$(${SINGBOX_BIN} generate reality-keypair)
    local pk=$(echo "$keypair" | awk '/PrivateKey/ {print $2}'); local pbk=$(echo "$keypair" | awk '/PublicKey/ {print $2}'); local sid=$(${SINGBOX_BIN} generate rand --hex 8)
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$uuid" --arg sn "$server_name" --arg pk "$pk" --arg sid "$sid" '{"type":"vless","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sn,"reality":{"enabled":true,"handshake":{"server":$sn,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound] | .inbounds |= unique_by(.tag)" || return 1
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": {publicKey:\"$pbk\", shortId:\"$sid\", name:\"$name\"}}" || return 1
    local proxy=$(jq -n --arg n "$name" --arg s "$node_ip" --arg p "$port" --arg u "$uuid" --arg sn "$server_name" --arg pbk "$pbk" --arg sid "$sid" '{"name":$n,"type":"vless","server":$s,"port":($p|tonumber),"uuid":$u,"tls":true,"network":"tcp","flow":"xtls-rprx-vision","servername":$sn,"client-fingerprint":"chrome","reality-opts":{"public-key":$pbk,"short-id":$sid}}')
    _add_node_to_yaml "$proxy"; _success "VLESS-Reality 节点 [${name}] 添加成功"; _show_node_link "vless-reality" "$name" "$link_ip" "$port" "$uuid" "$server_name" "$pbk" "$sid"
}
_add_vless_tcp() {
    local node_ip="${server_ip}" port="" name=""
    read -p "监听端口: " port
    [[ -z "$port" ]] && _error "端口不能为空" && return 1    
    read -p "名称 (默认 VLESS-TCP): " cn; name=${cn:-"VLESS-TCP"}
    local safe_name=$(_sanitize_tag "$name"); local tag="${safe_name}_${port}"; if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then tag="${tag}_$(openssl rand -hex 2)"; fi
    local uuid=$(${SINGBOX_BIN} generate uuid); local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$uuid" '{"type":"vless","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"uuid":$u,"flow":""}],"tls":{"enabled":false}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound] | .inbounds |= unique_by(.tag)" || return 1
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": {name:\"$name\"}}" || return 1
    local proxy=$(jq -n --arg n "$name" --arg s "$node_ip" --arg p "$port" --arg u "$uuid" '{"name":$n,"type":"vless","server":$s,"port":($p|tonumber),"uuid":$u,"tls":false,"network":"tcp"}')
    _add_node_to_yaml "$proxy"; _success "VLESS-TCP 节点 [${name}] 添加成功"; _show_node_link "vless-tcp" "$name" "$link_ip" "$port" "$uuid"
}
_add_hysteria2() {
    local node_ip="${server_ip}" port="" server_name="www.apple.com" obfs_password="" port_hopping="" use_multiport="false" name=""
    read -p "监听端口: " port
    [[ -z "$port" ]] && _error "端口不能为空" && return 1
    read -p "伪装域名 (默认 www.apple.com): " sn; server_name=${sn:-"www.apple.com"}; read -p "名称 (默认 Hysteria2): " cn; name=${cn:-"Hysteria2"}
    local safe_name=$(_sanitize_tag "$name"); local tag="${safe_name}_${port}"; if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then tag="${tag}_$(openssl rand -hex 2)"; fi
    local cert_path="${SINGBOX_DIR}/${tag}.pem"; local key_path="${SINGBOX_DIR}/${tag}.key"; _generate_self_signed_cert "$server_name" "$cert_path" "$key_path" || return 1
    read -p "密码(回车随机): " pw; password=${pw:-$(${SINGBOX_BIN} generate rand --hex 16)}
    read -p "开启 QUIC 混淆? (y/N): " hc; [[ "$hc" == "y" ]] && obfs_password=$(${SINGBOX_BIN} generate rand --hex 16)
    read -p "开启端口跳跃? (y/N): " hopc; if [[ "$hopc" == "y" ]]; then read -p "范围 (20000-30000): " port_hopping; if [[ "$port_hopping" =~ ^([0-9]+)-([0-9]+)$ ]]; then port_range_start="${BASH_REMATCH[1]}"; port_range_end="${BASH_REMATCH[2]}"; [ $((port_range_end - port_range_start + 1)) -le 1000 ] && use_multiport="true"; fi; fi
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$password" --arg op "$obfs_password" --arg cert "$cert_path" --arg key "$key_path" '{"type":"hysteria2","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"password":$pw}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}} | if $op != "" then .obfs={"type":"salamander","password":$op} else . end')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound] | .inbounds |= unique_by(.tag)" || return 1
    if [ "$use_multiport" == "true" ]; then
        local multi="["; local first=true
        for ((p=port_range_start; p<=port_range_end; p++)); do
            [ "$p" -eq "$port" ] && continue; [ "$first" = true ] && first=false || multi+=","
            local hop_tag="${tag}-hop-${p}"; local item=$(jq -n --arg t "$hop_tag" --arg p "$p" --arg pw "$password" --arg cert "$cert_path" --arg key "$key_path" '{"type": "hysteria2", "tag": $t, "listen": "::", "listen_port": ($p|tonumber), "users": [{"password": $pw}], "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": $cert, "key_path": $key}}')
            [ -n "$obfs_password" ] && item=$(echo "$item" | jq --arg op "$obfs_password" '.obfs={"type":"salamander","password":$op}'); multi+="$item"
        done
        multi+="]"; _atomic_modify_json "$CONFIG_FILE" ".inbounds += $multi | .inbounds |= unique_by(.tag)" || return 1
    fi
    local meta=$(jq -n --arg op "$obfs_password" --arg hop "$port_hopping" --arg nm "$name" '{name:$nm} | if $op != "" then .obfsPassword = $op else . end | if $hop != "" then .portHopping = $hop else . end')
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": $meta}" || return 1
    local proxy=$(jq -n --arg n "$name" --arg s "$node_ip" --arg p "$port" --arg pw "$password" --arg sn "$server_name" --arg op "$obfs_password" --arg hop "$port_hopping" '{"name": $n, "type": "hysteria2", "server": $s, "port": ($p|tonumber), "password": $pw, "sni": $sn, "skip-cert-verify": true, "alpn": ["h3"], "up": "500 Mbps", "down": "500 Mbps"} | if $op != "" then .obfs = "salamander" | .["obfs-password"] = $op else . end | if $hop != "" then .ports = $hop else . end')
    _add_node_to_yaml "$proxy"; _success "Hysteria2 节点 [${name}] 添加成功"; _show_node_link "hysteria2" "$name" "$link_ip" "$port" "$password" "$server_name" "$obfs_password" "$port_hopping"
}
_add_tuic() {
    local node_ip="${server_ip}" port="" server_name="www.apple.com" name=""
    read -p "监听端口: " port
    [[ -z "$port" ]] && _error "端口不能为空" && return 1
    read -p "SNI(默认 www.apple.com): " sn; server_name=${sn:-"www.apple.com"}; read -p "名称 (默认 TUICv5): " cn; name=${cn:-"TUICv5"}
    local safe_name=$(_sanitize_tag "$name"); local tag="${safe_name}_${port}"; if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then tag="${tag}_$(openssl rand -hex 2)"; fi
    local cert_path="${SINGBOX_DIR}/${tag}.pem" key_path="${SINGBOX_DIR}/${tag}.key"; _generate_self_signed_cert "$server_name" "$cert_path" "$key_path" || return 1
    local uuid=$(${SINGBOX_BIN} generate uuid); local password=$(${SINGBOX_BIN} generate rand --hex 16); local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$uuid" --arg pw "$password" --arg cert "$cert_path" --arg key "$key_path" '{"type":"tuic","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"uuid":$u,"password":$pw}],"congestion_control":"bbr","tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound] | .inbounds |= unique_by(.tag)" || return 1
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": {name:\"$name\"}}" || return 1
    local proxy=$(jq -n --arg n "$name" --arg s "$node_ip" --arg p "$port" --arg u "$uuid" --arg pw "$password" --arg sn "$server_name" '{"name":$n,"type":"tuic","server":$s,"port":($p|tonumber),"uuid":$u,"password":$pw,"sni":$sn,"skip-cert-verify":true,"alpn":["h3"],"udp-relay-mode":"native","congestion-controller":"bbr"}')
    _add_node_to_yaml "$proxy"; _success "TUICv5 节点 [${name}] 添加成功"; _show_node_link "tuic" "$name" "$link_ip" "$port" "$uuid" "$password" "$server_name"
}
_add_shadowsocks_menu() {
    echo "1) aes-256-gcm  2) ss-2022  3) ss-2022+Padding"; read -p "选择: " choice
    local method="" password="" name_prefix="" use_multiplex=false
    case $choice in
        1) method="aes-256-gcm"; password=$(${SINGBOX_BIN} generate rand --hex 16); name_prefix="SS-aes-256-gcm" ;;
        2) method="2022-blake3-aes-128-gcm"; password=$(${SINGBOX_BIN} generate rand --base64 16); name_prefix="SS-2022" ;;
        3) method="2022-blake3-aes-128-gcm"; password=$(${SINGBOX_BIN} generate rand --base64 16); name_prefix="SS-2022-Padding"; use_multiplex=true ;;
        *) return 1 ;;
    esac
    read -p "监听端口: " port
    [[ -z "$port" ]] && _error "端口不能为空" && return 1
    read -p "名称 (默认 ${name_prefix}): " cn; name=${cn:-"${name_prefix}"}
    local safe_name=$(_sanitize_tag "$name"); local tag="${safe_name}_${port}"; if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then tag="${tag}_$(openssl rand -hex 2)"; fi
    local link_ip="${server_ip}"; [[ "$server_ip" == *":"* ]] && link_ip="[$server_ip]"
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg m "$method" --arg pw "$password" '{"type": "shadowsocks", "tag": $t, "listen": "::", "listen_port": ($p|tonumber), "method": $m, "password": $pw}')
    [ "$use_multiplex" == "true" ] && inbound=$(echo "$inbound" | jq '.multiplex = {"enabled": true, "padding": true}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound] | .inbounds |= unique_by(.tag)" || return 1
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": {name:\"$name\"}}" || return 1
    local proxy=$(jq -n --arg n "$name" --arg s "$server_ip" --arg p "$port" --arg m "$method" --arg pw "$password" '{"name": $n, "type": "ss", "server": $s, "port": ($p|tonumber), "cipher": $m, "password": $pw}')
    [ "$use_multiplex" == "true" ] && proxy=$(echo "$proxy" | jq '.smux = {"enabled": true, "padding": true}')
    _add_node_to_yaml "$proxy"; _success "Shadowsocks 节点 [${name}] 添加成功"; _show_node_link "shadowsocks" "$name" "$link_ip" "$port" "$method" "$password"
}
_add_socks() {
    local port="" u="" p="" name=""
    read -p "监听端口: " port
    [[ -z "$port" ]] && _error "端口不能为空" && return 1
    read -p "用户: " u; u=${u:-$(${SINGBOX_BIN} generate rand --hex 8)}; read -p "密码: " p; p=${p:-$(${SINGBOX_BIN} generate rand --hex 16)}; read -p "名称 (默认 SOCKS5): " cn; name=${cn:-"SOCKS5"}
    local safe_name=$(_sanitize_tag "$name"); local tag="${safe_name}_${port}"; if jq -e ".inbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then tag="${tag}_$(openssl rand -hex 2)"; fi
    local link_ip="${server_ip}"; [[ "$server_ip" == *":"* ]] && link_ip="[$server_ip]"
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$u" --arg pw "$p" '{"type":"socks","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"username":$u,"password":$pw}]}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound] | .inbounds |= unique_by(.tag)" || return 1
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": {name:\"$name\"}}" || return 1
    local proxy=$(jq -n --arg n "$name" --arg s "$link_ip" --arg p "$port" --arg u "$u" --arg pw "$p" '{"name":$n,"type":"socks5","server":$s,"port":($p|tonumber),"username":$u,"password":$pw}')
    _add_node_to_yaml "$proxy"; _success "SOCKS5 节点添加成功"; _show_node_link "socks" "$name" "$link_ip" "$port" "$u" "$p"
}
_view_nodes() {
    if ! jq -e '.inbounds | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then _warning "无节点"; return; fi
    _info "--- 节点信息 (普通节点) ---"
    rm -f /tmp/singbox_links.tmp
    jq -c '.inbounds[]' "$CONFIG_FILE" | while read -r node; do
        local tag=$(echo "$node" | jq -r '.tag'); 
        if [[ "$tag" == *"-hop-"* ]] || [[ "$tag" == "argo_"* ]]; then continue; fi
        if [ -f "$ARGO_METADATA_FILE" ] && jq -e ".\"$tag\"" "$ARGO_METADATA_FILE" >/dev/null 2>&1; then continue; fi
        local type=$(echo "$node" | jq -r '.type'); local port=$(echo "$node" | jq -r '.listen_port')
        local dn=$(jq -r --arg t "$tag" '.[$t].name // empty' "$METADATA_FILE"); if [ -z "$dn" ]; then dn=$(echo "$tag" | sed "s/_${port}$//" | tr '_' ' '); fi; [ -z "$dn" ] && dn="$tag"
        local link_ip="${server_ip}"; [[ "$server_ip" == *":"* ]] && link_ip="[$server_ip]"
        local pn=$(${YQ_BINARY} eval '.proxies[] | select(.name == "'"$dn"'") | .name' ${CLASH_YAML_FILE} | head -1)
        echo "──────────────────────────────────────"; _info " 节点: ${dn}"; local url=""
        case "$type" in
            "vless")
                 local uuid=$(echo "$node" | jq -r '.users[0].users[0].uuid // .users[0].uuid')
                 if [ "$(echo "$node" | jq -r '.tls.reality.enabled // false')" == "true" ]; then
                     local meta=$(jq -r --arg t "$tag" '.[$t]' "$METADATA_FILE"); local pk=$(echo "$meta" | jq -r '.publicKey'); local sid=$(echo "$meta" | jq -r '.shortId')
                     url="vless://${uuid}@${link_ip}:${port}?security=reality&encryption=none&pbk=${pk}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=$(echo "$node" | jq -r '.tls.server_name')&sid=${sid}#$(_url_encode "$dn")"
                 elif [ "$(echo "$node" | jq -r '.transport.type')" == "ws" ]; then
                      local sn=$(_get_proxy_field "$pn" ".servername"); local path=$(echo "$node" | jq -r '.transport.path')
                      url="vless://${uuid}@${link_ip}:${port}?security=tls&encryption=none&type=ws&host=${sn}&path=$(_url_encode "$path")&sni=${sn}#$(_url_encode "$dn")"
                 else url="vless://${uuid}@${link_ip}:${port}?encryption=none&type=tcp#$(_url_encode "$dn")"; fi ;;
            "trojan")
                 local pw=$(echo "$node" | jq -r '.users[0].password')
                 if [ "$(echo "$node" | jq -r '.transport.type')" == "ws" ]; then
                      local sn=$(_get_proxy_field "$pn" ".sni"); local path=$(echo "$node" | jq -r '.transport.path')
                      url="trojan://${pw}@${link_ip}:${port}?security=tls&type=ws&host=${sn}&path=$(_url_encode "$path")&sni=${sn}#$(_url_encode "$dn")"
                 else local sn=$(_get_proxy_field "$pn" ".sni"); url="trojan://${pw}@${link_ip}:${port}?security=tls&type=tcp&sni=${sn}#$(_url_encode "$dn")"; fi ;;
            "hysteria2")
                 local pw=$(echo "$node" | jq -r '.users[0].password'); local sn=$(echo "$node" | jq -r '.tls.server_name'); local meta=$(jq -r --arg t "$tag" '.[$t]' "$METADATA_FILE")
                 local op=$(echo "$meta" | jq -r '.obfsPassword'); local obfs_param=""; [[ -n "$op" && "$op" != "null" ]] && obfs_param="&obfs=salamander&obfs-password=${op}"; local hop=$(echo "$meta" | jq -r '.portHopping // empty'); local hop_param=""; [[ -n "$hop" && "$hop" != "null" ]] && hop_param="&mport=${hop}"
                 url="hysteria2://${pw}@${link_ip}:${port}?sni=${sn}&insecure=1${obfs_param}${hop_param}#$(_url_encode "$dn")" ;;
            "tuic") local u=$(echo "$node" | jq -r '.users[0].uuid'); local pw=$(echo "$node" | jq -r '.users[0].password'); local sn=$(echo "$node" | jq -r '.tls.server_name'); url="tuic://${u}:${pw}@${link_ip}:${port}?sni=${sn}&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#$(_url_encode "$dn")" ;;
            "anytls") local pw=$(echo "$node" | jq -r '.users[0].password'); local sn=$(echo "$node" | jq -r '.tls.server_name'); local sv=$(_get_proxy_field "$pn" ".skip-cert-verify"); local iparam=""; [ "$sv" == "true" ] && iparam="&insecure=1&allowInsecure=1"; url="anytls://${pw}@${link_ip}:${port}?security=tls&sni=${sn}${iparam}&type=tcp#$(_url_encode "$dn")" ;;
            "shadowsocks") local m=$(echo "$node" | jq -r '.method'); local p=$(echo "$node" | jq -r '.password'); url="ss://$(_url_encode "${m}:${p}")@${link_ip}:${port}#$(_url_encode "$dn")" ;;
            "socks") echo "  SOCKS5";;
        esac
        [ -n "$url" ] && echo -e "  链接: ${url}" && echo "$url" >> /tmp/singbox_links.tmp
    done
    if [ -f /tmp/singbox_links.tmp ]; then read -p "生成聚合 Base64? (y/N): " gen; if [[ "$gen" == "y" ]]; then echo -e "\n${CYAN}$(cat /tmp/singbox_links.tmp | base64 -w 0)${NC}\n"; fi; rm -f /tmp/singbox_links.tmp; fi
}
_delete_node() {
    if ! jq -e '.inbounds | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then _warning "无节点"; return; fi
    _info "   节点删除  "
    local tags=(); local ports=(); local types=(); local names=(); local i=1
    while IFS= read -r node; do
        local tag=$(echo "$node" | jq -r '.tag'); [[ "$tag" == *"-hop-"* ]] && continue
        if [[ "$tag" == "argo_"* ]]; then continue; fi
        if [ -f "$ARGO_METADATA_FILE" ] && jq -e ".\"$tag\"" "$ARGO_METADATA_FILE" >/dev/null 2>&1; then continue; fi
        local type=$(echo "$node" | jq -r '.type'); local port=$(echo "$node" | jq -r '.listen_port')
        tags+=("$tag"); ports+=("$port"); types+=("$type")
        local dn=$(jq -r --arg t "$tag" '.[$t].name // empty' "$METADATA_FILE"); if [ -z "$dn" ]; then dn=$(echo "$tag" | sed "s/_${port}$//" | tr '_' ' '); fi; names+=("$dn")
        echo -e "  ${CYAN}$i)${NC} ${dn} (${YELLOW}${type}${NC}) @ ${port}"; ((i++))
    done < <(jq -c '.inbounds[]' "$CONFIG_FILE")
    echo -e "  ${RED}99)${NC} 删除所有"
    read -p "编号 (0返回): " num; [[ "$num" == "0" ]] && return
    if [ "$num" == "99" ]; then
         _atomic_modify_json "$CONFIG_FILE" '.inbounds = []'; _atomic_modify_json "$METADATA_FILE" '{}'
         ${YQ_BINARY} eval '.proxies = []' -i "$CLASH_YAML_FILE"
         rm -f ${SINGBOX_DIR}/*.pem ${SINGBOX_DIR}/*.key 2>/dev/null; if command -v iptables &>/dev/null; then iptables -t nat -F PREROUTING 2>/dev/null; _save_iptables_rules; fi
         _success "已清空"; _manage_service "restart"; return
    fi
    if [ "$num" -gt "${#tags[@]}" ]; then return; fi
    local idx=$((num - 1)); local tag=${tags[$idx]}; local type=${types[$idx]}; local name=${names[$idx]}; local p=${ports[$idx]}
    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))"
    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag | startswith(\"$tag-hop-\")))"
    _atomic_modify_json "$METADATA_FILE" "del(.\"$tag\")"
    _remove_node_from_yaml "$name"
    if [[ "$type" =~ ^(hysteria2|tuic|anytls)$ ]]; then rm -f "${SINGBOX_DIR}/${tag}.pem" "${SINGBOX_DIR}/${tag}.key"; fi
    _success "删除成功"; _manage_service "restart"
}
_modify_port() {
    if ! jq -e '.inbounds | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then _warning "无节点"; return; fi
    _info "   修改端口  "
    local tags=(); local ports=(); local types=(); local names=(); local i=1
    while IFS= read -r node; do
        local tag=$(echo "$node" | jq -r '.tag'); 
        if [[ "$tag" == *"-hop-"* ]] || [[ "$tag" == "argo_"* ]]; then continue; fi
        if [ -f "$ARGO_METADATA_FILE" ] && jq -e ".\"$tag\"" "$ARGO_METADATA_FILE" >/dev/null 2>&1; then continue; fi
        local type=$(echo "$node" | jq -r '.type'); local port=$(echo "$node" | jq -r '.listen_port')
        tags+=("$tag"); ports+=("$port"); types+=("$type")
        local dn=$(jq -r --arg t "$tag" '.[$t].name // empty' "$METADATA_FILE"); if [ -z "$dn" ]; then dn=$(echo "$tag" | sed "s/_${port}$//" | tr '_' ' '); fi; names+=("$dn")
        echo -e "  ${CYAN}$i)${NC} ${dn} (${type}) @ ${port}"; ((i++))
    done < <(jq -c '.inbounds[]' "$CONFIG_FILE")
    read -p "编号 (0返回): " num; [[ "$num" == "0" ]] && return
    local idx=$((num - 1)); local old_tag=${tags[$idx]}; local old_port=${ports[$idx]}; local type=${types[$idx]}; local name=${names[$idx]}
    read -p "请输入新端口: " new_port
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 0 ] || [ "$new_port" -gt 65535 ]; then _error "无效端口"; return; fi
    local base_tag_name=$(echo "$old_tag" | sed "s/_${old_port}.*//"); local new_tag="${base_tag_name}_${new_port}"
    if jq -e ".inbounds[] | select(.tag == \"$new_tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then new_tag="${new_tag}_$(openssl rand -hex 2)"; fi
    if [[ "$type" =~ ^(hysteria2|tuic|anytls|vless|trojan) ]]; then
        if [ -f "${SINGBOX_DIR}/${old_tag}.pem" ]; then mv "${SINGBOX_DIR}/${old_tag}.pem" "${SINGBOX_DIR}/${new_tag}.pem"; fi
        if [ -f "${SINGBOX_DIR}/${old_tag}.key" ]; then mv "${SINGBOX_DIR}/${old_tag}.key" "${SINGBOX_DIR}/${new_tag}.key"; fi
    fi
    _atomic_modify_json "$CONFIG_FILE" "(.inbounds[] | select(.tag == \"$old_tag\")) |= (.tag = \"$new_tag\" | .listen_port = ($new_port|tonumber))"
    _atomic_modify_json "$CONFIG_FILE" "(.inbounds[] | select(.tag == \"$new_tag\").tls) |= (if .certificate_path then .certificate_path = \"${SINGBOX_DIR}/${new_tag}.pem\" | .key_path = \"${SINGBOX_DIR}/${new_tag}.key\" else . end)"
    local meta=$(jq -r ".\"$old_tag\"" "$METADATA_FILE")
    _atomic_modify_json "$METADATA_FILE" "del(.\"$old_tag\") | . + {\"$new_tag\": $meta}"
    PROXY_NAME="$name" ${YQ_BINARY} eval '(.proxies[] | select(.name == env(PROXY_NAME))) |= (.port = '"$new_port"')' -i "$CLASH_YAML_FILE"
    _manage_service "restart"; _success "端口已修改"
}
_check_config() { if ${SINGBOX_BIN} check -c ${CONFIG_FILE}; then _success "配置正确"; else _error "配置错误"; fi; }

# [核心修复] 更新函数：强制调用 install.sh 
_update_script() {
    _info "正在调用官方安装脚本进行全量更新..."
    
    # 优先使用 curl，其次 wget
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$INSTALL_SCRIPT_URL" | bash
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$INSTALL_SCRIPT_URL" | bash
    else
        _error "未找到 curl 或 wget，无法更新"
        return 1
    fi
    
    _success "更新完成，请重新运行脚本。"
    exit 0
}

_update_singbox_core() { _install_sing_box; _manage_service "restart"; }
_show_add_node_menu() {
    local CYAN='\033[0;36m'; local WHITE='\033[1;37m'; local GREY='\033[0;37m'; local NC='\033[0m'
    clear; echo -e "\n\n\n              ${CYAN}A D D   N O D E${NC}\n    ${GREY}─────────────────────────────────${NC}\n"
    echo -e "     ${WHITE}01.${NC} VLESS-Reality     ${WHITE}02.${NC} VLESS-WS-TLS"
    echo -e "     ${WHITE}03.${NC} Trojan-WS-TLS     ${WHITE}04.${NC} AnyTLS"
    echo -e "     ${WHITE}05.${NC} Hysteria2         ${WHITE}06.${NC} TUICv5"
    echo -e "     ${WHITE}07.${NC} Shadowsocks       ${WHITE}08.${NC} VLESS-TCP"
    echo -e "     ${WHITE}09.${NC} SOCKS5            ${WHITE}00.${NC} 返回"
    echo -e "\n"; read -e -p "     选择 > " c
    case $c in
        1|01) _add_vless_reality ;; 2|02) _add_vless_ws_tls ;; 3|03) _add_trojan_ws_tls ;; 4|04) _add_anytls ;;
        5|05) _add_hysteria2 ;; 6|06) _add_tuic ;; 7|07) _add_shadowsocks_menu ;; 8|08) _add_vless_tcp ;; 
        9|09) _add_socks ;; 0|00) return ;;
        *) return ;; 
    esac; _manage_service "restart"
}
_quick_deploy() {
    _init_server_ip
    local p1=$(shuf -i 10000-60000 -n 1); local p2=$(shuf -i 10000-60000 -n 1); while [ $p2 -eq $p1 ]; do p2=$(shuf -i 10000-60000 -n 1); done
    local p3=$(shuf -i 10000-60000 -n 1); while [[ $p3 -eq $p1 || $p3 -eq $p2 ]]; do p3=$(shuf -i 10000-60000 -n 1); done
    export BATCH_MODE="true" BATCH_SNI="www.apple.com"
    export BATCH_PORT="$p1"; _add_vless_reality
    export BATCH_PORT="$p2"; _add_hysteria2
    export BATCH_PORT="$p3"; _add_tuic
    unset BATCH_MODE BATCH_PORT BATCH_SNI; _manage_service "restart"
    _success "快速部署完成！"
}

_do_scheduled_start() {
    _info "执行定时启动任务..." >> "$LOG_FILE"
    _manage_service "start"
    if [ -f "$ARGO_METADATA_FILE" ] && [ "$(jq 'length' "$ARGO_METADATA_FILE")" -gt 0 ]; then
        _enable_argo_watchdog; _argo_keepalive
    fi
}
_do_scheduled_stop() {
     _info "执行定时停止任务..." >> "$LOG_FILE"
     _disable_argo_watchdog; _stop_all_argo_tunnels; _manage_service "stop"
}
_scheduled_lifecycle_menu() {
    echo -e " ${CYAN}   定时启停管理  ${NC}"
    echo -e " 当前时间: ${YELLOW}$(date "+%Y-%m-%d %H:%M:%S") (CST)${NC}"
    local start_key="scheduled_start"; local stop_key="scheduled_stop"
    local existing_start=$(crontab -l 2>/dev/null | grep "${start_key}" | tail -n 1)
    local existing_stop=$(crontab -l 2>/dev/null | grep "${stop_key}" | tail -n 1)
    if [ -n "$existing_start" ] && [ -n "$existing_stop" ]; then
        local s_m=$(echo "$existing_start" | awk '{print $1}'); local s_h=$(echo "$existing_start" | awk '{print $2}')
        local e_m=$(echo "$existing_stop" | awk '{print $1}'); local e_h=$(echo "$existing_stop" | awk '{print $2}')
        printf " 状态: ${GREEN}已启用${NC} (启动 %02d:%02d | 停止 %02d:%02d)\n" $((s_h)) $((s_m)) $((e_h)) $((e_m))
    else echo -e " 状态: ${RED}未启用${NC}"; fi
    echo ""; echo -e " [1] 设置/修改   [2] 删除   [0] 返回"
    read -p "选择: " c
    if [ "$c" == "1" ]; then
        echo -e "${YELLOW}请输入 24小时制时间 (格式 HH:MM)${NC}"
        read -p "启动时间 (如 08:30): " start_input; read -p "停止时间 (如 23:15): " stop_input
        if [[ "$start_input" != *":"* ]] || [[ "$stop_input" != *":"* ]]; then _error "格式错误"; return; fi
        local s_h=$((10#$(echo "$start_input" | cut -d: -f1))); local s_m=$((10#$(echo "$start_input" | cut -d: -f2)))
        local e_h=$((10#$(echo "$stop_input" | cut -d: -f1))); local e_m=$((10#$(echo "$stop_input" | cut -d: -f2)))
        if [ "$s_h" -gt 23 ] || [ "$s_m" -gt 59 ] || [ "$e_h" -gt 23 ] || [ "$e_m" -gt 59 ]; then _error "时间不合法"; return; fi
        
        _cron_lock # 加锁
        crontab -l 2>/dev/null | grep -v "${start_key}" | grep -v "${stop_key}" > /tmp/cron.tmp
        echo "$s_m $s_h * * * bash ${SELF_SCRIPT_PATH} ${start_key} >> $LOG_FILE 2>&1" >> /tmp/cron.tmp
        echo "$e_m $e_h * * * bash ${SELF_SCRIPT_PATH} ${stop_key} >> $LOG_FILE 2>&1" >> /tmp/cron.tmp
        crontab /tmp/cron.tmp && rm -f /tmp/cron.tmp && _success "设置成功" || _error "设置失败"
        _cron_unlock # 解锁
        
    elif [ "$c" == "2" ]; then
        _cron_lock
        crontab -l 2>/dev/null | grep -v "${start_key}" | grep -v "${stop_key}" | crontab -
        _cron_unlock
        _success "已移除"
    fi
}
_main_menu() {
    local CYAN='\033[0;36m'; local WHITE='\033[1;37m'; local GREY='\033[0;37m'; local GREEN='\033[0;32m'
    local RED='\033[1;31m'; local YELLOW='\033[0;33m'; local NC='\033[0m'
    while true; do
        clear; echo -e "\n\n${CYAN}   M A K E R   Z   -   N E T W O R K${NC}"
        local os_info=$(grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1); [ -z "$os_info" ] && os_info=$(uname -s)
        local service_status="${RED}● Stopped${NC}"; local argo_status="${GREY}○ Missing${NC}"
        if [ "$INIT_SYSTEM" == "systemd" ]; then systemctl is-active --quiet sing-box 2>/dev/null && service_status="${GREEN}● Running${NC}"; elif [ "$INIT_SYSTEM" == "openrc" ]; then rc-service sing-box status 2>/dev/null | grep -q "started" && service_status="${GREEN}● Running${NC}"; fi
        if [ -f "$CLOUDFLARED_BIN" ]; then if pgrep -f "cloudflared" >/dev/null 2>&1; then argo_status="${GREEN}● Running${NC}"; else argo_status="${YELLOW}● Stopped${NC}"; fi; fi
        echo -e "  ${GREY}───────────────────────────────────────────${NC}"
        echo -e "   SYSTEM: ${WHITE}${os_info}${NC}"
        echo -e "   CORE  : ${service_status}      ARGO  : ${argo_status}"
        echo -e "  ${GREY}───────────────────────────────────────────${NC}"
        echo -e "    ${CYAN}NODE MANAGER${NC}"
        echo -e "    ${WHITE}01.${NC} 添加节点            ${WHITE}02.${NC} Argo 隧道"
        echo -e "    ${WHITE}03.${NC} 查看链接            ${WHITE}04.${NC} 删除节点"
        echo -e "    ${WHITE}05.${NC} 修改端口"
        echo -e "    ${CYAN}SERVICE CONTROL${NC}"
        echo -e "    ${WHITE}06.${NC} 重启服务            ${WHITE}07.${NC} 停止服务"
        echo -e "    ${WHITE}08.${NC} 运行状态            ${WHITE}09.${NC} 实时日志"
        echo -e "    ${WHITE}10.${NC} 定时启停 "
        echo -e "    ${CYAN}MAINTENANCE${NC}"
        echo -e "    ${WHITE}11.${NC} 检查配置            ${WHITE}12.${NC} 全量更新"
        echo -e "    ${WHITE}13.${NC} 更新核心            ${RED}14.${NC} 卸载脚本"
        echo -e "\n  ${GREY}───────────────────────────────────────────${NC}"
        echo -e "    ${WHITE}00.${NC} 退出"
        echo -e ""; read -e -p "  选择 > " choice
        case $choice in
            1|01) _show_add_node_menu ;; 2|02) _argo_menu ;; 3|03) _view_nodes ;; 4|04) _delete_node ;; 5|05) _modify_port ;;
            6|06) _manage_service "restart" ;; 7|07) _manage_service "stop" ;; 8|08) _manage_service "status" ;; 9|09) _view_log ;; 
            10) _scheduled_lifecycle_menu ;; 11) _check_config ;; 12) _update_script ;; 13) _update_singbox_core ;; 14) _uninstall ;;
            0|00) exit 0 ;;
            *) echo -e "\n  ${GREY}无效输入...${NC}"; sleep 1 ;;
        esac
        echo -e ""; read -n 1 -s -r -p "  按键返回..."
    done
}

main() {
    _check_root; _detect_init_system
    if [ "$INIT_SYSTEM" == "openrc" ]; then SERVICE_FILE="/etc/init.d/sing-box"; else SERVICE_FILE="/etc/systemd/system/sing-box.service"; fi
    [ -f "${LOG_FILE}" ] && [ $(stat -c%s "${LOG_FILE}") -gt 10485760 ] && : > "${LOG_FILE}"
    
    # [新增] 完整性自检：检查 lib 库是否存在，不存在则尝试修复
    if [ ! -f "${INSTALL_DIR_DEFAULT}/utils.sh" ]; then 
        _info "检测到文件缺失，正在尝试修复..."
        _update_script
    fi
    
    _set_beijing_timezone
    mkdir -p "${SINGBOX_DIR}" 2>/dev/null
    _install_dependencies; _init_server_ip
    local first=false
    if [ ! -f "${SINGBOX_BIN}" ]; then _install_sing_box; first=true; fi
    if [ ! -f "${CONFIG_FILE}" ]; then _initialize_config_files; fi
    _cleanup_legacy_config; _create_service_files
    if [ "$first" = true ]; then _manage_service "start"; fi
    if [ "$QUICK_DEPLOY_MODE" = true ]; then _quick_deploy; exit 0; fi
    _main_menu
}

while [[ $# -gt 0 ]]; do 
    case "$1" in 
        -q|--quick-deploy) QUICK_DEPLOY_MODE=true; shift ;; 
        keepalive) _argo_keepalive; exit 0 ;; 
        scheduled_start) _do_scheduled_start; exit 0 ;;
        scheduled_stop) _do_scheduled_stop; exit 0 ;;
        *) shift ;; 
    esac
done
main
