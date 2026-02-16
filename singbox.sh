#!/bin/bash

# 基础路径定义
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SINGBOX_DIR="/usr/local/etc/sing-box"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/Zzz-IT/-Singbox-Maker-Z/main"

SCRIPT_UPDATE_URL="${GITHUB_RAW_BASE}/singbox.sh"

# --- 核心组件自动补全函数 ---
_download_missing_component() {
    local name="$1"
    local target="$2"
    echo "检测到缺失核心组件: $name，正在尝试自动补全..."
    if command -v curl &>/dev/null; then
        curl -LfSs "$GITHUB_RAW_BASE/$name" -o "$target"
    elif command -v wget &>/dev/null; then
        wget -qO "$target" "$GITHUB_RAW_BASE/$name"
    else
        echo "错误: 未找到 curl 或 wget，无法自动补全缺失组件。"
        exit 1
    fi
    [ -f "$target" ] && chmod +x "$target"
}

# --- 引入工具库 ---
if [ -f "$SCRIPT_DIR/utils.sh" ]; then
    source "$SCRIPT_DIR/utils.sh"
elif [ -f "${SINGBOX_DIR}/utils.sh" ]; then
    source "${SINGBOX_DIR}/utils.sh"
else
    mkdir -p "${SINGBOX_DIR}"
    _download_missing_component "utils.sh" "${SINGBOX_DIR}/utils.sh"
    if [ -f "${SINGBOX_DIR}/utils.sh" ]; then
        source "${SINGBOX_DIR}/utils.sh"
    else
        echo "错误: 核心组件 utils.sh 缺失且自动补全失败。"
        exit 1
    fi
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
SELF_SCRIPT_PATH=$(readlink -f "$0")
PID_FILE="/var/run/singbox_manager.pid"

# 脚本版本 (仅内部记录)
SCRIPT_VERSION="12-Scheduled-Lifecycle"

# 捕获退出信号
trap 'rm -f ${SINGBOX_DIR}/*.tmp /tmp/singbox_links.tmp' EXIT

# --- Tag 净化函数 ---
_sanitize_tag() {
    local raw_name="$1"
    local clean_name=$(echo "$raw_name" | tr ' ' '_')
    clean_name=$(echo "$clean_name" | tr -cd '[:alnum:]_\-\u4e00-\u9fa5')
    if [ -z "$clean_name" ]; then echo "node_$(date +%s)"; else echo "$clean_name"; fi
}

# 依赖安装
_install_dependencies() {
    # 基础依赖
    local pkgs="curl jq openssl wget procps iptables socat tar iproute2"
    
    # 根据发行版判断 cron 包名
    if command -v apk &>/dev/null; then
        pkgs="$pkgs dcron"  # Alpine 使用 dcron
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        pkgs="$pkgs cronie" # RHEL系 使用 cronie
    else
        pkgs="$pkgs cron"   # Debian/Ubuntu 使用 cron
    fi

    local needs_install=false
    for pkg in $pkgs; do
        # 针对 crontab 命令的特殊检测
        if [[ "$pkg" == *"cron"* ]]; then
            if ! command -v crontab &>/dev/null; then
                needs_install=true
                break
            fi
        else
            if ! command -v $pkg &>/dev/null && ! dpkg -l $pkg &>/dev/null 2>&1 && ! apk info -e $pkg &>/dev/null 2>&1; then
                needs_install=true
                break
            fi
        fi
    done

    if [ "$needs_install" = true ]; then 
        _info "正在预装依赖 (含计划任务服务)..."
        _pkg_install $pkgs
        
        # 确保 cron 服务已启动
        if [ "$INIT_SYSTEM" == "systemd" ]; then
            systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null
            systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null
        elif [ "$INIT_SYSTEM" == "openrc" ]; then
            rc-update add crond default 2>/dev/null
            rc-service crond start 2>/dev/null
        fi
    fi
    _install_yq
}

# --- 自动设置北京时间函数 ---
_set_beijing_timezone() {
    # 检查当前时区是否已经是 CST (Asia/Shanghai)
    if date | grep -q "CST"; then
        return
    fi

    _info "检测到时区非北京时间，正在自动修正..."
    
    # 1. Alpine Linux 处理逻辑
    if [ -f /etc/alpine-release ]; then
        if ! apk info -e tzdata >/dev/null 2>&1; then
            apk add --no-cache tzdata >/dev/null 2>&1
        fi
        cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
        _success "Alpine 时区已修正为北京时间"
        return
    fi

    # 2. Debian/Ubuntu/CentOS (Systemd) 处理逻辑
    if command -v timedatectl &>/dev/null; then
        # 使用标准 systemd 工具
        timedatectl set-timezone Asia/Shanghai
        _success "Systemd 时区已修正为北京时间"
    else
        # 容器或精简环境的回退方案 (直接软链接)
        if [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
            rm -f /etc/localtime
            ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
            echo "Asia/Shanghai" > /etc/timezone
            _success "强制修正时区文件为北京时间"
        else
            _warn "未找到时区文件，跳过设置。"
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
    if [ -z "$download_url" ]; then _error "无法获取 sing-box 下载链接。"; exit 1; fi
    wget -qO sing-box.tar.gz "$download_url" || { _error "下载失败!"; exit 1; }
    local temp_dir=$(mktemp -d)
    tar -xzf sing-box.tar.gz -C "$temp_dir"
    mv "$temp_dir/sing-box-"*"/sing-box" ${SINGBOX_BIN}
    rm -rf sing-box.tar.gz "$temp_dir"
    chmod +x ${SINGBOX_BIN}
    _success "sing-box 安装成功"
}

_install_cloudflared() {
    if [ -f "${CLOUDFLARED_BIN}" ]; then return 0; fi
    _info "正在安装 cloudflared..."
    local arch=$(uname -m)
    local arch_tag
    case $arch in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='arm' ;;
        *) _error "不支持的架构：$arch"; return 1 ;;
    esac
    local download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch_tag}"
    wget -qO "${CLOUDFLARED_BIN}" "$download_url" || { _error "cloudflared 下载失败!"; return 1; }
    chmod +x "${CLOUDFLARED_BIN}"
    _success "cloudflared 安装成功"
}

# --- Argo Tunnel 功能 ---
_start_argo_tunnel() {
    local target_port="$1"; local protocol="$2"; local token="$3" 
    local pid_file="/tmp/singbox_argo_${target_port}.pid"
    local log_file="/tmp/singbox_argo_${target_port}.log"
    
    _info "正在启动 Argo 隧道 (端口: $target_port)..." >&2
    
    # 每次启动前清理旧日志
    rm -f "${log_file}"

    if [ -n "$token" ]; then
        # 固定隧道：直接丢弃所有日志，防止占用内存
        nohup ${CLOUDFLARED_BIN} tunnel run --token "$token" > /dev/null 2>&1 &
        local cf_pid=$!; echo "$cf_pid" > "${pid_file}"; sleep 5
        if ! kill -0 "$cf_pid" 2>/dev/null; then _error "启动失败" >&2; return 1; fi
        _success "Argo 固定隧道启动成功" >&2; return 0
    else
        # 临时隧道：抓取域名后立即清空日志
        nohup ${CLOUDFLARED_BIN} tunnel --url "http://localhost:${target_port}" --logfile "${log_file}" > /dev/null 2>&1 &
        local cf_pid=$!; echo "$cf_pid" > "${pid_file}"
        local tunnel_domain=""; local wait_count=0
        while [ $wait_count -lt 30 ]; do
            sleep 2; wait_count=$((wait_count + 2))
            if ! kill -0 "$cf_pid" 2>/dev/null; then return 1; fi
            if [ -f "${log_file}" ]; then
                tunnel_domain=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "${log_file}" 2>/dev/null | tail -1 | sed 's|https://||')
                if [ -n "$tunnel_domain" ]; then 
                    : > "${log_file}" # 关键修复：清空日志文件，防止其无限增长
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

_add_argo_vless_ws() {
    _info " 创建 VLESS-WS + Argo 隧道节点 "
    _install_cloudflared || return 1
    
    # 端口配置
    read -p "请输入 Argo 内部监听端口 (回车随机生成): " input_port
    local port="$input_port"
    if [[ -z "$port" ]] || [[ ! "$port" =~ ^[0-9]+$ ]]; then
        port=$(shuf -i 10000-60000 -n 1)
        _info "已随机分配内部端口: ${port}"
    fi
    
    # 路径配置
    read -p "请输入 WebSocket 路径 (回车随机生成): " ws_path
    [ -z "$ws_path" ] && ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
    [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
    
    # 模式选择
    echo ""
    echo "请选择隧道模式:"
    echo "  1. 临时隧道 (无需配置, 随机域名, 重启失效)"
    echo "  2. 固定隧道 (需 Token, 自定义域名, 稳定持久)"
    read -p "请选择 [1/2] (默认: 1): " mode; mode=${mode:-1}
    
    local token=""; local domain=""; local type="temp"
    if [ "$mode" == "2" ]; then
        type="fixed"
        echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
        echo -e "${CYAN} 固定隧道 Token 获取指南${NC} "
        echo "  1. 访问 https://one.dash.cloudflare.com/"
        echo "  2. 进入 Networks -> Tunnels -> Create a tunnel"
        echo "  3. 选择 Cloudflared，点击 Next"
        echo "  4. 设置隧道名称，保存"
        echo "  5. 在 'Install and run a connector' 页面，选择 Debian -> 64-bit"
        echo "  6. 复制下方出现的安装命令 (通常以 sudo cloudflared service install ... 开头)"
        echo "  7. 将完整的命令粘贴到下方即可，脚本会自动提取 Token"
        echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
        
        read -p "请粘贴 Token 或 完整安装命令: " input_token
        token=$(echo "$input_token" | grep -oE 'ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' | head -1)
        [ -z "$token" ] && token=$(echo "$input_token" | grep -oE 'ey[A-Za-z0-9_-]{20,}' | head -1)
        [ -z "$token" ] && token="$input_token"
        
        if [ -z "$token" ]; then _error "未识别到有效的 Token！"; return 1; fi
        _info "已识别 Token (前20位): ${token:0:20}..."
        
        echo ""
        read -p "请输入该 Tunnel 绑定的域名 (例如 tunnel.example.com): " domain
        if [ -z "$domain" ]; then _error "域名不能为空"; return 1; fi
       
        echo -e "${YELLOW} 请去 CF 配置回源 Public Hostname: ${domain} -> Service: http://localhost:${port}${NC}"
        read -n 1 -s -r -p "按任意键继续..."
        echo ""
    fi

    local default_name="Argo-Vless" 
    read -p "请输入节点名称 (默认: ${default_name}): " name
    name=${name:-$default_name}
    
    local safe_name=$(_sanitize_tag "$name")
    local tag="argo_vless_${port}_${safe_name}"
    local uuid=$(${SINGBOX_BIN} generate uuid)
    
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$uuid" --arg w "$ws_path" '{"type":"vless","tag":$t,"listen":"127.0.0.1","listen_port":($p|tonumber),"users":[{"uuid":$u,"flow":""}],"transport":{"type":"ws","path":$w}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound]" || return 1
    
    _manage_service "restart"; sleep 2
    
    if [ "$type" == "fixed" ]; then
        _start_argo_tunnel "$port" "vless-ws" "$token" || return 1
    else
        domain=$(_start_argo_tunnel "$port" "vless-ws")
        [ -z "$domain" ] && return 1
    fi
    
    local meta=$(jq -n --arg t "$tag" --arg n "$name" --arg d "$domain" --arg p "$port" --arg u "$uuid" --arg w "$ws_path" --arg ty "$type" --arg tok "$token" '{($t):{name:$n,domain:$d,local_port:($p|tonumber),uuid:$u,path:$w,protocol:"vless-ws",type:$ty,token:$tok}}')
    [ ! -f "$ARGO_METADATA_FILE" ] && echo '{}' > "$ARGO_METADATA_FILE"
    _atomic_modify_json "$ARGO_METADATA_FILE" ". + $meta"
    
    local proxy=$(jq -n --arg n "$name" --arg s "$domain" --arg u "$uuid" --arg w "$ws_path" '{"name":$n,"type":"vless","server":$s,"port":443,"uuid":$u,"tls":true,"network":"ws","servername":$s,"ws-opts":{"path":$w,"headers":{"Host":$s}}}')
    _add_node_to_yaml "$proxy"
    _enable_argo_watchdog
    _success "Argo 节点创建成功！"
}

_add_argo_trojan_ws() {
    _info " 创建 Trojan-WS + Argo 隧道节点 "
    _install_cloudflared || return 1
    
    read -p "请输入 Argo 内部监听端口 (回车随机生成): " input_port
    local port="$input_port"
    if [[ -z "$port" ]] || [[ ! "$port" =~ ^[0-9]+$ ]]; then
        port=$(shuf -i 10000-60000 -n 1)
        _info "已随机分配内部端口: ${port}"
    fi
    
    read -p "请输入 WebSocket 路径 (回车随机生成): " ws_path
    [ -z "$ws_path" ] && ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
    [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
    
    read -p "请输入密码 (回车随机): " password
    [ -z "$password" ] && password=$(${SINGBOX_BIN} generate rand --hex 16)
    
    echo ""
    echo "请选择隧道模式:"
    echo "  1. 临时隧道 (无需配置, 随机域名, 重启失效)"
    echo "  2. 固定隧道 (需 Token, 自定义域名, 稳定持久)"
    read -p "请选择 [1/2] (默认: 1): " mode; mode=${mode:-1}
    
    local token=""; local domain=""; local type="temp"
    if [ "$mode" == "2" ]; then
        type="fixed"
        # ... (同上 VLESS 的详细提示) ...
        echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
        echo -e "${CYAN} 固定隧道 Token 获取指南 ${NC}"
        echo "  请粘贴 Cloudflare Tunnel Token (支持直接粘贴CF网页端安装命令):"
        echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
        read -p "Token: " input_token
        token=$(echo "$input_token" | grep -oE 'ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' | head -1)
        [ -z "$token" ] && token=$(echo "$input_token" | grep -oE 'ey[A-Za-z0-9_-]{20,}' | head -1)
        [ -z "$token" ] && token="$input_token"
        if [ -z "$token" ]; then _error "Token 无效"; return 1; fi
        _info "已识别 Token (前20位): ${token:0:20}..."
        
        read -p "请输入绑定的域名: " domain
        if [ -z "$domain" ]; then _error "域名不能为空"; return 1; fi
        
        echo -e "${YELLOW} 请去 CF 配置回源 Public Hostname: ${domain} -> Service: http://localhost:${port}${NC}"
        read -n 1 -s -r -p "按任意键继续..."
        echo ""
    fi
    
    local default_name="Argo-Trojan"
    read -p "请输入节点名称 (默认: ${default_name}): " name
    name=${name:-$default_name}
    
    local safe_name=$(_sanitize_tag "$name")
    local tag="argo_trojan_${port}_${safe_name}"
    
    local inbound=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$password" --arg w "$ws_path" '{"type":"trojan","tag":$t,"listen":"127.0.0.1","listen_port":($p|tonumber),"users":[{"password":$pw}],"transport":{"type":"ws","path":$w}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound]" || return 1
    
    _manage_service "restart"; sleep 2
    
    if [ "$type" == "fixed" ]; then
        _start_argo_tunnel "$port" "trojan-ws" "$token" || return 1
    else
        domain=$(_start_argo_tunnel "$port" "trojan-ws")
        [ -z "$domain" ] && return 1
    fi
    
    local meta=$(jq -n --arg t "$tag" --arg n "$name" --arg d "$domain" --arg p "$port" --arg pw "$password" --arg w "$ws_path" --arg ty "$type" --arg tok "$token" '{($t):{name:$n,domain:$d,local_port:($p|tonumber),password:$pw,path:$w,protocol:"trojan-ws",type:$ty,token:$tok}}')
    [ ! -f "$ARGO_METADATA_FILE" ] && echo '{}' > "$ARGO_METADATA_FILE"
    _atomic_modify_json "$ARGO_METADATA_FILE" ". + $meta"
    
    local proxy=$(jq -n --arg n "$name" --arg s "$domain" --arg pw "$password" --arg w "$ws_path" '{"name":$n,"type":"trojan","server":$s,"port":443,"password":$pw,"tls":true,"network":"ws","sni":$s,"ws-opts":{"path":$w,"headers":{"Host":$s}}}')
    _add_node_to_yaml "$proxy"
    _enable_argo_watchdog
    _success "Argo 节点创建成功！"
}

_view_argo_nodes() {
    _info "   Argo 节点列表    "
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then
        _warning "没有 Argo 隧道节点。"
        return
    fi
    
    echo "────────────────────────────────────────────────────────"
    jq -r 'to_entries[] | "\(.value.name)|\(.value.type)|\(.value.protocol)|\(.value.local_port)|\(.value.domain)|\(.value.uuid // "")|\(.value.path // "")|\(.value.password // "")"' "$ARGO_METADATA_FILE" | \
    while IFS='|' read -r name type protocol port domain uuid path password; do
        echo -e "节点: ${GREEN}${name}${NC}"
        echo -e "  协议: ${protocol} | 端口: ${port}"
        
        local pid_file="/tmp/singbox_argo_${port}.pid"
        if [ -f "$pid_file" ] && kill -0 $(cat "$pid_file") 2>/dev/null; then
             echo -e "  状态: ${GREEN}运行中${NC}"
             if [ "$type" == "temp" ] || [ -z "$domain" ] || [ "$domain" == "null" ]; then
                  local log_file="/tmp/singbox_argo_${port}.log"
                  local temp_domain=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -1 | sed 's|https://||')
                   [ -n "$temp_domain" ] && domain="$temp_domain"
             fi
        else
             echo -e "  状态: ${RED}已停止${NC}"
        fi
        echo -e "  域名: ${CYAN}${domain}${NC}"
        
        # 显示完整链接
        if [ -n "$domain" ] && [ "$domain" != "null" ]; then
             local safe_name=$(_url_encode "$name")
             local safe_path=$(_url_encode "$path")
             local link=""
             if [[ "$protocol" == "vless-ws" ]]; then
                 link="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${safe_path}&sni=${domain}#${safe_name}"
             elif [[ "$protocol" == "trojan-ws" ]]; then
                 local safe_pw=$(_url_encode "$password")
                 link="trojan://${safe_pw}@${domain}:443?security=tls&type=ws&host=${domain}&path=${safe_path}&sni=${domain}#${safe_name}"
             fi
             [ -n "$link" ] && echo -e "  ${YELLOW}链接:${NC} $link"
        fi
        echo "────────────────────────────────────────────────────────"
    done
}

_delete_argo_node() {
    [ ! -f "$ARGO_METADATA_FILE" ] && return
    local i=1; local keys=(); local names=(); local ports=()
    while IFS='|' read -r key name port; do
        keys+=("$key"); names+=("$name"); ports+=("$port")
        echo -e " ${CYAN}$i)${NC} ${name} (端口: $port)"
        ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)"' "$ARGO_METADATA_FILE")
    
    echo " 0) 返回"
    read -p "请选择要删除的节点: " choice
    [[ "$choice" == "0" || -z "$choice" ]] && return
    
    local idx=$((choice - 1))
    local n=${names[$idx]}; local p=${ports[$idx]}; local k=${keys[$idx]}
    
    echo -e "${RED}─────────────────────────────────────────────${NC}"
    echo -e "  即将删除 Argo 节点: ${CYAN}${n}${NC}"
    echo -e "  本地监听端口: ${GREEN}${p}${NC}"
    echo -e "${RED}─────────────────────────────────────────────${NC}"
    read -p "$(echo -e ${YELLOW}"确认删除? (y/N): "${NC})" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then return; fi
    
    _stop_argo_tunnel "$p"
    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$k\"))"
    jq "del(.\"$k\")" "$ARGO_METADATA_FILE" > "${ARGO_METADATA_FILE}.tmp" && mv "${ARGO_METADATA_FILE}.tmp" "$ARGO_METADATA_FILE"
    _remove_node_from_yaml "$n"
    _manage_service "restart"
    _success "Argo 节点已删除。"
}

_restart_argo_tunnel_menu() {
    [ ! -f "$ARGO_METADATA_FILE" ] && return
    local i=1; local keys=(); local names=(); local ports=(); local protos=(); local types=(); local tokens=()
    while IFS='|' read -r k n p pr ty tok; do
        keys+=("$k"); names+=("$n"); ports+=("$p"); protos+=("$pr"); types+=("$ty"); tokens+=("$tok")
        echo -e "$i) $n ($p)"; ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)|\(.value.protocol)|\(.value.type)|\(.value.token)"' "$ARGO_METADATA_FILE")
    read -p "重启编号 (a全部, 0返回): " c; [[ "$c" == "0" ]] && return
    local idxs=(); if [ "$c" == "a" ]; then for ((j=0;j<${#keys[@]};j++)); do idxs+=($j); done; else idxs+=($((c-1))); fi
    for idx in "${idxs[@]}"; do
        local p=${ports[$idx]}; local ty=${types[$idx]}; local pr=${protos[$idx]}; local tok=${tokens[$idx]}; local k=${keys[$idx]}
        _stop_argo_tunnel "$p"; sleep 1
        if [ "$ty" == "fixed" ]; then _start_argo_tunnel "$p" "$pr" "$tok"
        else local dom=$(_start_argo_tunnel "$p" "$pr"); [ -n "$dom" ] && jq ".\"$k\".domain = \"$dom\"" "$ARGO_METADATA_FILE" > "${ARGO_METADATA_FILE}.tmp" && mv "${ARGO_METADATA_FILE}.tmp" "$ARGO_METADATA_FILE"; fi
    done
    _success "完成"
}

_stop_argo_menu() { _stop_all_argo_tunnels; _success "已停止所有隧道"; }
_argo_keepalive() {
    local lock="/tmp/singbox_keepalive.lock"; [ -f "$lock" ] && kill -0 $(cat "$lock") 2>/dev/null && return
    echo "$$" > "$lock"; trap 'rm -f "$lock"' RETURN EXIT
    [ ! -f "$ARGO_METADATA_FILE" ] && return
    local tags=$(jq -r 'keys[]' "$ARGO_METADATA_FILE")
    for tag in $tags; do
        local port=$(jq -r ".\"$tag\".local_port" "$ARGO_METADATA_FILE"); local type=$(jq -r ".\"$tag\".type" "$ARGO_METADATA_FILE"); local token=$(jq -r ".\"$tag\".token // empty" "$ARGO_METADATA_FILE"); local pid="/tmp/singbox_argo_${port}.pid"
        if [ ! -f "$pid" ] || ! kill -0 $(cat "$pid") 2>/dev/null; then
            if [ "$type" == "fixed" ]; then _start_argo_tunnel "$port" "fixed" "$token"
            else local d=$(_start_argo_tunnel "$port" "temp"); [ -n "$d" ] && _atomic_modify_json "$ARGO_METADATA_FILE" ".\"$tag\".domain = \"$d\""; fi
        fi
    done
}
_enable_argo_watchdog() { local j="* * * * * bash ${SELF_SCRIPT_PATH} keepalive >/dev/null 2>&1"; ! crontab -l 2>/dev/null | grep -Fq "$j" && (crontab -l 2>/dev/null; echo "$j") | crontab -; }
_disable_argo_watchdog() { local j="bash ${SELF_SCRIPT_PATH} keepalive"; crontab -l 2>/dev/null | grep -Fv "$j" | crontab -; }
_uninstall_argo() {
    _stop_all_argo_tunnels
    if [ -f "$ARGO_METADATA_FILE" ]; then
        local tags=$(jq -r 'keys[]' "$ARGO_METADATA_FILE")
        for t in $tags; do _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$t\"))"; local n=$(jq -r ".\"$t\".name" "$ARGO_METADATA_FILE"); _remove_node_from_yaml "$n"; done
    fi
    _disable_argo_watchdog; rm -f "${CLOUDFLARED_BIN}" "${ARGO_METADATA_FILE}" /tmp/singbox_argo_*; rm -rf "/etc/cloudflared"; _manage_service "restart"; _success "已卸载"
}
_argo_menu() {
    # 颜色定义放循环外，稍微提高一点性能
    local CYAN='\033[0;36m'
    local WHITE='\033[1;37m'
    local GREY='\033[0;37m'
    local NC='\033[0m'

    while true; do
        clear
        # 顶部留白
        echo -e "\n\n\n"

        # 标题区
        echo -e "      ${CYAN}A R G O   T U N N E L   M A N A G E R${NC}"
        echo -e "  ${GREY}──────────────────────────────────────────${NC}"
        echo -e ""

        # 选项区
        echo -e "  ${WHITE}01.${NC}  部署 VLESS 隧道"
        echo -e "  ${WHITE}02.${NC}  部署 Trojan 隧道"
        echo -e ""
        echo -e "  ${WHITE}03.${NC}  查看节点详情"
        echo -e "  ${WHITE}04.${NC}  删除配置节点"
        echo -e ""
        echo -e "  ${WHITE}05.${NC}  重启服务"
        echo -e "  ${WHITE}06.${NC}  停止服务"
        echo -e "  ${WHITE}07.${NC}  卸载服务"  # <--- 补上了这个漏掉的选项
        echo -e ""
        echo -e "  ${GREY}──────────────────────────────────────────${NC}"
        echo -e "  ${WHITE}00.${NC}  退出系统"
        echo -e "\n"

        # 输入区优化：增加缩进，并兼容 01 和 1 的输入
        read -e -p "  请输入选项 > " c
        
        case $c in
            1|01) _add_argo_vless_ws ;;
            2|02) _add_argo_trojan_ws ;;
            3|03) _view_argo_nodes ;;
            4|04) _delete_argo_node ;;
            5|05) _restart_argo_tunnel_menu ;;
            6|06) _stop_argo_menu ;;
            7|07) _uninstall_argo ;;
            0|00) return ;;
            *) echo -e "\n  ${GREY}无效输入，请重试...${NC}"; sleep 1 ;;
        esac
        
        # 这里的暂停逻辑可以根据需要调整，如果执行完不想暂停直接回菜单，可以删掉下面这行
        read -n 1 -s -r -p "  按任意键继续..."
    done
}
# --- 服务与配置管理 ---
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
    local proxy=$(jq -n --arg n "$name" --arg s "$client_server_addr" --arg p "$client_port" --arg pw "$password" --arg sn "$camouflage_domain" --arg w "$ws_path" --arg sv "$skip_verify" '{"name":$n,"type":"trojan","server":$s,"port":($p|tonumber),"password":$pw,"udp":true,"skip-cert-verify":($sv=="true"),"network":"ws","sni":$sn,"ws-opts":{"path":$w,"headers":{"Host":$sn}}}')
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
        # [修改] 双重过滤 Argo 节点
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
        # [修改] 同样双重过滤 Argo 节点
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
    echo -e "${RED}─────────────────────────────────────────────${NC}"
    echo -e "  即将删除节点: ${CYAN}${name}${NC}"
    echo -e "  协议类型: ${YELLOW}${type}${NC}"
    echo -e "  监听端口: ${GREEN}${p}${NC}"
    echo -e "${RED}─────────────────────────────────────────────${NC}"
    read -p "$(echo -e ${YELLOW}"是否确认删除此节点? (y/N): "${NC})" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then return; fi
    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))"
    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag | startswith(\"$tag-hop-\")))"
    _atomic_modify_json "$METADATA_FILE" "del(.\"$tag\")"
    _remove_node_from_yaml "$name"
    if [[ "$type" =~ ^(hysteria2|tuic|anytls)$ ]]; then rm -f "${SINGBOX_DIR}/${tag}.pem" "${SINGBOX_DIR}/${tag}.key"; fi
    _success "节点 $name 已删除"; _manage_service "restart"
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
    _manage_service "restart"; _success "端口已修改: $old_port -> $new_port"
}

_check_config() { if ${SINGBOX_BIN} check -c ${CONFIG_FILE}; then _success "配置 (${CONFIG_FILE}) 正确"; else _error "配置错误"; fi; }
_update_script() {
    _info "正在更新主脚本..."
    local temp="${SELF_SCRIPT_PATH}.tmp"
    if wget -qO "$temp" "$SCRIPT_UPDATE_URL"; then 
        chmod +x "$temp"
        mv "$temp" "$SELF_SCRIPT_PATH"
        _success "主脚本更新成功！"
    else 
        _error "下载失败"
    fi
    _info "正在更新 utils.sh..."
    local u_path="${SINGBOX_DIR}/utils.sh"
    if wget -qO "$u_path" "${GITHUB_RAW_BASE}/utils.sh"; then
        chmod +x "$u_path"
        _success "utils.sh 更新成功"
    else
        _error "utils.sh 下载失败"
    fi
    exit 0
}
_update_singbox_core() { _install_sing_box; _manage_service "restart"; }
_show_add_node_menu() {
    # 局部颜色定义
    local CYAN='\033[0;36m'
    local WHITE='\033[1;37m'
    local GREY='\033[0;37m'
    local NC='\033[0m'

    clear
    # 顶部留白
    echo -e "\n\n\n"

    # 标题区：已修复居中
    # 标题缩进 14 空格，分割线缩进 4 空格，长度 45
    echo -e "              ${CYAN}A D D   N O D E   M E N U${NC}"
    echo -e "    ${GREY}─────────────────────────────────────────────${NC}"
    echo -e ""

    # 选项区：双列布局 (缩进 5 空格)
    # 第一组：主流协议
    echo -e "     ${WHITE}01.${NC}  VLESS-Reality       ${WHITE}02.${NC}  VLESS-WS-TLS"
    echo -e "     ${WHITE}03.${NC}  Trojan-WS-TLS       ${WHITE}04.${NC}  AnyTLS"
    echo -e ""
    
    # 第二组：高性能/UDP
    echo -e "     ${WHITE}05.${NC}  Hysteria2           ${WHITE}06.${NC}  TUICv5"
    
    # 第三组：传统/基础
    echo -e "     ${WHITE}07.${NC}  Shadowsocks         ${WHITE}08.${NC}  VLESS-TCP"
    echo -e "     ${WHITE}09.${NC}  SOCKS5"

    echo -e ""
    echo -e "    ${GREY}─────────────────────────────────────────────${NC}"
    echo -e "     ${WHITE}00.${NC}  返回主菜单"
    echo -e "\n"

    # 输入区 (对齐缩进)
    read -e -p "     请选择协议 > " c
    
    case $c in
        1|01) _add_vless_reality ;; 
        2|02) _add_vless_ws_tls ;; 
        3|03) _add_trojan_ws_tls ;; 
        4|04) _add_anytls ;;
        5|05) _add_hysteria2 ;; 
        6|06) _add_tuic ;; 
        7|07) _add_shadowsocks_menu ;; 
        8|08) _add_vless_tcp ;; 
        9|09) _add_socks ;;
        0|00) return ;;
        *) echo -e "\n     ${GREY}无效选项，取消操作...${NC}"; sleep 1; return ;; 
    esac

    # 只有在有效操作后才重启服务
    _manage_service "restart"
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

# --- 定时启停功能 ---
_do_scheduled_start() {
    _info "执行定时启动任务..." >> "$LOG_FILE"
    _manage_service "start"
    # 恢复 Argo 守护
    if [ -f "$ARGO_METADATA_FILE" ] && [ "$(jq 'length' "$ARGO_METADATA_FILE")" -gt 0 ]; then
        _enable_argo_watchdog
        _argo_keepalive # 立即尝试拉起一次
    fi
}

_do_scheduled_stop() {
     _info "执行定时停止任务..." >> "$LOG_FILE"
     # 先关守护，防止自愈
     _disable_argo_watchdog
     _stop_all_argo_tunnels
     _manage_service "stop"
}

_scheduled_lifecycle_menu() {
    echo -e " ${CYAN}   定时启停管理  ${NC}"
    echo -e " 功能说明: 每天指定时间(精确到分)自动启动和停止所有服务"
    echo -e " 系统时间: ${YELLOW}$(date "+%Y-%m-%d %H:%M:%S") (CST)${NC}"
    
    local start_key="scheduled_start"
    local stop_key="scheduled_stop"
    local start_cron="bash ${SELF_SCRIPT_PATH} ${start_key}"
    local stop_cron="bash ${SELF_SCRIPT_PATH} ${stop_key}"
    
    # --- 读取状态 (优化版) ---
    # 强制只取最后一行匹配项，防止多行干扰
    local existing_start=$(crontab -l 2>/dev/null | grep "${start_key}" | tail -n 1)
    local existing_stop=$(crontab -l 2>/dev/null | grep "${stop_key}" | tail -n 1)
    
    if [ -n "$existing_start" ] && [ -n "$existing_stop" ]; then
        # 提取 Crontab 中的 分钟($1) 和 小时($2)
        local s_m=$(echo "$existing_start" | awk '{print $1}')
        local s_h=$(echo "$existing_start" | awk '{print $2}')
        local e_m=$(echo "$existing_stop" | awk '{print $1}')
        local e_h=$(echo "$existing_stop" | awk '{print $2}')
        
        # 显示当前状态
        printf " 当前状态: ${GREEN}已启用${NC} (启动: %02d:%02d | 停止: %02d:%02d)\n" $((s_h)) $((s_m)) $((e_h)) $((e_m))
    else
        echo -e " 当前状态: ${RED}未启用${NC}"
    fi
    echo ""
    echo -e " ${GREEN}[1]${NC} 设置/修改 定时计划"
    echo -e " ${RED}[2]${NC} 删除 定时计划"
    echo -e " ${YELLOW}[0]${NC} 返回"
    
    read -p "选择: " c
    if [ "$c" == "1" ]; then
        echo -e "${YELLOW}请输入 24小时制时间 (格式 HH:MM)${NC}"
        read -p "启动时间 (例如 08:30): " start_input
        read -p "停止时间 (例如 23:15): " stop_input
        
        # --- 简单格式检查 (确保包含冒号) ---
        if [[ "$start_input" != *":"* ]] || [[ "$stop_input" != *":"* ]]; then
            _error "时间格式错误! 必须包含冒号 (例如 08:30)"
            return
        fi

        # --- 核心修改：使用 cut 进行纯文本切割 (100% 可靠) ---
        
        # 处理启动时间
        local s_h_raw=$(echo "$start_input" | cut -d: -f1)
        local s_m_raw=$(echo "$start_input" | cut -d: -f2)
        # 强制转为十进制数字，去除前导0 (比如 08 -> 8)
        local s_h=$((10#$s_h_raw))
        local s_m=$((10#$s_m_raw))
        
        # 处理停止时间
        local e_h_raw=$(echo "$stop_input" | cut -d: -f1)
        local e_m_raw=$(echo "$stop_input" | cut -d: -f2)
        # 强制转为十进制数字
        local e_h=$((10#$e_h_raw))
        local e_m=$((10#$e_m_raw))

        # --- 数值合法性检查 ---
        if [ "$s_h" -gt 23 ] || [ "$s_m" -gt 59 ] || [ "$e_h" -gt 23 ] || [ "$e_m" -gt 59 ]; then
             _error "时间数值不合法 (小时 0-23, 分钟 0-59)"
             return
        fi
        
        _info "正在更新定时任务..."
        
        # --- 原子写入逻辑 ---
        # 1. 过滤掉旧任务
        crontab -l 2>/dev/null | grep -v "${start_key}" | grep -v "${stop_key}" > /tmp/cron.tmp
        
        # 2. 写入新任务 (注意变量名不要写错)
        echo "$s_m $s_h * * * $start_cron >> $LOG_FILE 2>&1" >> /tmp/cron.tmp
        echo "$e_m $e_h * * * $stop_cron >> $LOG_FILE 2>&1" >> /tmp/cron.tmp
        
        # 3. 应用 Crontab
        if crontab /tmp/cron.tmp; then
            rm -f /tmp/cron.tmp
            # 再次确认显示给用户看
            _success "定时计划已设置：启动 ${s_h}:${s_m} | 停止 ${e_h}:${e_m}"
        else
            rm -f /tmp/cron.tmp
            _error "写入 Crontab 失败，请检查系统权限。"
        fi
        
    elif [ "$c" == "2" ]; then
        crontab -l 2>/dev/null | grep -v "${start_key}" | grep -v "${stop_key}" | crontab -
        _success "定时计划已移除。"
    fi
}
_main_menu() {
    # 局部颜色定义，防止污染全局变量
    local CYAN='\033[0;36m'
    local WHITE='\033[1;37m'
    local GREY='\033[0;37m'
    local GREEN='\033[0;32m'
    local RED='\033[1;31m'
    local YELLOW='\033[0;33m'
    local NC='\033[0m'

    while true; do
        clear
        # 顶部留白，增加呼吸感
        echo -e "\n\n"

        # ----------------------------------------------------------------
        # 1. 抬头区域 (ASCII Art)
        # ----------------------------------------------------------------
        echo -e "${CYAN}"
        echo '   _____ _               __                 '
        echo '  / ___/(_)___  ____    / /_  ____  _  __   '
        echo '  \__ \/ / __ \/ __ \  / __ \/ __ \| |/_/   '
        echo ' ___/ / / / / / /_/ / / /_/ / /_/ />  <     '
        echo '/____/_/_/ /_/\__, / /_.___/\____/_/|_|     '
        echo '             /____/         [ M A K E R  Z ] '
        echo -e "${NC}"
        
      
        echo -e "      ${CYAN}N E T W O R K   D A S H B O A R D${NC}"
        
        # ----------------------------------------------------------------
        # 2. 系统信息仪表盘 (动态获取逻辑)
        # ----------------------------------------------------------------
        local os_info="Unknown"
        if [ -f /etc/os-release ]; then
            os_info=$(grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
            [ -z "$os_info" ] && os_info=$(grep -E "^NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
        fi
        [ -z "$os_info" ] && os_info=$(uname -s)

        # 状态判定逻辑
        local service_status="${RED}● Stopped${NC}"
        if [ "$INIT_SYSTEM" == "systemd" ]; then
            systemctl is-active --quiet sing-box 2>/dev/null && service_status="${GREEN}● Running${NC}"
        elif [ "$INIT_SYSTEM" == "openrc" ]; then
            rc-service sing-box status 2>/dev/null | grep -q "started" && service_status="${GREEN}● Running${NC}"
        fi

        local argo_status="${GREY}○ Not Installed${NC}"
        if [ -f "$CLOUDFLARED_BIN" ]; then
            if pgrep -f "cloudflared" >/dev/null 2>&1; then 
                argo_status="${GREEN}● Running${NC}"
            else 
                argo_status="${YELLOW}● Stopped${NC}"
            fi
        fi

        # 仪表盘显示区 (分割线与状态)
        echo -e "  ${GREY}───────────────────────────────────────────${NC}"
        echo -e "   ${CYAN}SYSTEM:${NC} ${WHITE}${os_info}${NC}"
        echo -e "   ${CYAN}CORE  :${NC} ${service_status}      ${CYAN}ARGO  :${NC} ${argo_status}"
        echo -e "  ${GREY}───────────────────────────────────────────${NC}"
        echo -e ""

        # ----------------------------------------------------------------
        # 3. 菜单选项区 (双列布局，简洁对齐)
        # ----------------------------------------------------------------
        
        # --- 节点管理 ---
        echo -e "    ${CYAN}NODE MANAGER${NC}"
        echo -e "    ${WHITE}01.${NC} 添加节点            ${WHITE}02.${NC} Argo 隧道"
        echo -e "    ${WHITE}03.${NC} 查看链接            ${WHITE}04.${NC} 删除节点"
        echo -e "    ${WHITE}05.${NC} 修改端口"
        echo -e ""

        # --- 服务控制 ---
        echo -e "    ${CYAN}SERVICE CONTROL${NC}"
        echo -e "    ${WHITE}06.${NC} 重启服务            ${WHITE}07.${NC} 停止服务"
        echo -e "    ${WHITE}08.${NC} 运行状态            ${WHITE}09.${NC} 实时日志"
        echo -e "    ${WHITE}10.${NC} 定时启停 "
        echo -e ""

        # --- 维护与更新 ---
        echo -e "    ${CYAN}MAINTENANCE${NC}"
        echo -e "    ${WHITE}11.${NC} 检查配置            ${WHITE}12.${NC} 更新脚本"
        echo -e "    ${WHITE}13.${NC} 更新核心            ${RED}14.${NC} 卸载脚本"
        
        echo -e "\n  ${GREY}───────────────────────────────────────────${NC}"
        echo -e "    ${WHITE}00.${NC} 退出脚本"
        echo -e ""

        # ----------------------------------------------------------------
        # 4. 输入处理 (兼容 01 和 1)
        # ----------------------------------------------------------------
        read -e -p "  请输入选项 > " choice
        case $choice in
            1|01) _show_add_node_menu ;; 
            2|02) _argo_menu ;; 
            3|03) _view_nodes ;; 
            4|04) _delete_node ;; 
            5|05) _modify_port ;;
            6|06) _manage_service "restart" ;; 
            7|07) _manage_service "stop" ;; 
            8|08) _manage_service "status" ;; 
            9|09) _view_log ;; 
            10)   _scheduled_lifecycle_menu ;; 
            11)   _check_config ;; 
            12)   _update_script ;; 
            13)   _update_singbox_core ;; 
            14)   _uninstall ;;
            0|00) exit 0 ;;
            *)    echo -e "\n  ${GREY}无效输入，请重试...${NC}"; sleep 1 ;;
        esac
        
        # 这里的 echo 是为了美观，防止 read -n 1 紧贴着上一行
        echo -e "" 
        read -n 1 -s -r -p "  按任意键返回主菜单..."
    done
}

main() {
    _check_root; _detect_init_system

    # [新增] 只有检测完系统后，才能确定服务文件路径
    if [ "$INIT_SYSTEM" == "openrc" ]; then
        SERVICE_FILE="/etc/init.d/sing-box"
    else
        SERVICE_FILE="/etc/systemd/system/sing-box.service"
    fi
    
    # --- [额外补充] 日志自动清理逻辑 ---
    # 如果日志文件存在且大于 10MB，则清空它
    [ -f "${LOG_FILE}" ] && [ $(stat -c%s "${LOG_FILE}") -gt 10485760 ] && : > "${LOG_FILE}"
    # ------------------------------------

    
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

# 参数监听修改，增加 scheduled_start 和 scheduled_stop
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
