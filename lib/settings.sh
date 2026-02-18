#!/usr/bin/env bash

# lib/settings.sh
# - 负责高级设置功能：日志、DNS、路由策略
# - 被 utils.sh 加载，依赖全局变量 $CONFIG_FILE

# --- 辅助函数：获取当前状态并转换为中文名称 ---

_get_current_log_level() {
    [ ! -f "$CONFIG_FILE" ] && echo "未知" && return
    local level=$(jq -r '.log.level // "error"' "$CONFIG_FILE")
    case "$level" in
        "error") echo "Error (错误)" ;;
        "warn")  echo "Warn (警告)" ;;
        "info")  echo "Info (信息)" ;;
        "debug") echo "Debug (调试)" ;;
        *) echo "$level" ;;
    esac
}

_get_current_dns_group() {
    [ ! -f "$CONFIG_FILE" ] && echo "未知" && return
    # 通过判断是否存在 bootstrap-cn 标签来区分
    if jq -e '.dns.servers[] | select(.tag == "bootstrap-cn")' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo "国内优先"
    else
        echo "国外优先"
    fi
}

_get_current_strategy() {
    [ ! -f "$CONFIG_FILE" ] && echo "未知" && return
    # 提取 action=resolve 的 strategy，默认为 prefer_ipv6
    local s=$(jq -r '.route.rules[]? | select(.action == "resolve")? | .strategy // empty' "$CONFIG_FILE" | head -1)
    [ -z "$s" ] && s="prefer_ipv6"
    case "$s" in
        "prefer_ipv6") echo "优先 IPv6" ;;
        "prefer_ipv4") echo "优先 IPv4" ;;
        "ipv4_only")   echo "仅 IPv4" ;;
        "ipv6_only")   echo "仅 IPv6" ;;
        *) echo "$s" ;;
    esac
}

# --- 功能函数 ---

# 01. 日志设置
_setting_log() {
    local current=$(_get_current_log_level)
    echo -e " ${CYAN}   日志配置  ${NC}"
    echo -e " ${YELLOW}当前状态: ${current}${NC}"
    echo -e ""
    echo -e "  ${WHITE}01.${NC} Error (仅错误 - 推荐/默认)"
    echo -e "  ${WHITE}02.${NC} Warn  (警告)"
    echo -e "  ${WHITE}03.${NC} Info  (信息 - 调试用)"
    echo -e "  ${WHITE}04.${NC} Debug (调试 - 极量日志)"
    echo -e ""
    echo -e "  ${GREY}00. 返回${NC}"
    echo -e ""
    
    read -p "请选择 [01-04]: " level_c

    local level="error"
    case "$level_c" in
        2|02) level="warn" ;;
        3|03) level="info" ;;
        4|04) level="debug" ;;
        1|01) level="error" ;;
        0|00) return ;;  
        *) echo -e "${RED}无效输入${NC}"; sleep 1; return ;;
    esac

    local log_json=$(jq -n --arg l "$level" '{"level": $l, "timestamp": false}')
    _atomic_modify_json "$CONFIG_FILE" ".log = $log_json"
    _success "日志等级已更新为: $level"
    
    read -p "需要重启服务生效，立即重启? (y/N): " r
    [[ "$r" == "y" || "$r" == "Y" ]] && _manage_service "restart"
}

# 02. DNS 设置
_setting_dns() {
    local current=$(_get_current_dns_group)
    echo -e " ${CYAN}   DNS 策略配置  ${NC}"
    echo -e " ${YELLOW}当前状态: ${current}${NC}"
    echo -e ""
    echo -e "  ${WHITE}01.${NC} 国外优先 (Cloudflare/Google/Quad9) [推荐]"
    echo -e "     ${GREY}适合: 境外 VPS，能够访问国际互联网的环境${NC}"
    echo -e "  ${WHITE}02.${NC} 国内优先 (AliDNS/DNSPod)"
    echo -e "     ${GREY}适合: 国内服务器或者VPS${NC}"
    echo -e ""
    echo -e "  ${GREY}00. 返回${NC}"
    echo -e ""

    read -p "请选择 [01-02]: " dns_c
    
    local dns_json=""
    case "$dns_c" in
        2|02) # 国内组
            dns_json='{
                "servers": [
                    {"type": "udp", "tag": "bootstrap-cn", "server": "223.5.5.5", "server_port": 53},
                    {"type": "https", "tag": "dns", "server": "dns.alidns.com", "path": "/dns-query", "domain_resolver": "bootstrap-cn"},
                    {"type": "https", "tag": "doh-tencent", "server": "doh.pub", "path": "/dns-query", "domain_resolver": "bootstrap-cn"}
                ]
            }'
            _info "已选择: 国内 DNS 组"
            ;;
        1|01) # 国外组
            dns_json='{
                "servers": [
                    {"type": "udp", "tag": "bootstrap-v4", "server": "1.1.1.1", "server_port": 53},
                    {"type": "https", "tag": "dns", "server": "cloudflare-dns.com", "path": "/dns-query", "domain_resolver": "bootstrap-v4"},
                    {"type": "https", "tag": "doh-google", "server": "dns.google", "path": "/dns-query", "domain_resolver": "bootstrap-v4"},
                    {"type": "https", "tag": "doh-quad9", "server": "dns.quad9.net", "path": "/dns-query", "domain_resolver": "bootstrap-v4"}
                ]
            }'
            _info "已选择: 国外 DNS 组"
            ;;
        0|00) return ;;
        *) echo -e "${RED}无效输入${NC}"; sleep 1; return ;;
    esac

    _atomic_modify_json "$CONFIG_FILE" ".dns = $dns_json"
    if ! jq -e '.route' "$CONFIG_FILE" >/dev/null 2>&1; then
         _atomic_modify_json "$CONFIG_FILE" '.route = {"final": "direct", "auto_detect_interface": true}'
    fi
    _atomic_modify_json "$CONFIG_FILE" '.route.default_domain_resolver = "dns"'

    _success "DNS 配置已更新"
    read -p "需要重启服务生效，立即重启? (y/N): " r
    [[ "$r" == "y" || "$r" == "Y" ]] && _manage_service "restart"
}

# 03. 出站/路由策略设置
_setting_strategy() {
    local current=$(_get_current_strategy)
    echo -e " ${CYAN}   IP 出站策略   ${NC}"
    echo -e " ${YELLOW}当前状态: ${current}${NC}"
    echo -e ""
    echo -e "  ${WHITE}01.${NC} 优先 IPv6 (prefer_ipv6) [默认]"
    echo -e "  ${WHITE}02.${NC} 优先 IPv4 (prefer_ipv4)"
    echo -e "  ${WHITE}03.${NC} 仅 IPv4   (ipv4_only)"
    echo -e "  ${WHITE}04.${NC} 仅 IPv6   (ipv6_only)"
    echo -e ""
    echo -e "  ${GREY}00. 返回${NC}"
    echo -e ""

    read -p "请选择 [01-04]: " s_c
    
    local strategy="prefer_ipv6"
    case "$s_c" in
        2|02) strategy="prefer_ipv4" ;;
        3|03) strategy="ipv4_only" ;;
        4|04) strategy="ipv6_only" ;;
        1|01) strategy="prefer_ipv6" ;;
        0|00) return ;;
        *) echo -e "${RED}无效输入${NC}"; sleep 1; return ;;
    esac

    local route_json=$(jq -n --arg s "$strategy" '{
        "default_domain_resolver": "dns",
        "rules": [
            {
                "action": "resolve",
                "strategy": $s,
                "disable_cache": false
            }
        ],
        "final": "direct"
    }')

    _atomic_modify_json "$CONFIG_FILE" ".route = $route_json"
    _success "出站策略已更新为: $strategy"
    
    read -p "需要重启服务生效，立即重启? (y/N): " r
    [[ "$r" == "y" || "$r" == "Y" ]] && _manage_service "restart"
}

# 04. 高级设置子菜单
_advanced_menu() {
    local CYAN='\033[0;36m'
    local WHITE='\033[1;37m'
    local GREY='\033[0;37m'
    local YELLOW='\033[0;33m'
    local NC='\033[0m'
    
    while true; do
        local s_log=$(_get_current_log_level)
        local s_dns=$(_get_current_dns_group)
        local s_str=$(_get_current_strategy)
        
        clear
        echo -e "\n\n"
        echo -e "       ${CYAN}A D V A N C E D   S E T T I N G S${NC}"
        echo -e "  ${GREY}─────────────────────────────────────────────${NC}"
        echo -e ""
        echo -e "  ${WHITE}01.${NC} 日志等级            ${NC}状态: ${YELLOW}${s_log}${NC}"
        echo -e "  ${WHITE}02.${NC} DNS 模式            ${NC}状态: ${YELLOW}${s_dns}${NC}"
        echo -e "  ${WHITE}03.${NC} IP 策略             ${NC}状态: ${YELLOW}${s_str}${NC}"
        echo -e ""
        echo -e "  ${GREY}─────────────────────────────────────────────${NC}"
        echo -e "  ${WHITE}00.${NC} 返回主菜单"
        echo -e "\n"
        
        read -e -p "  请输入选项 > " choice
        case "$choice" in
            1|01) _setting_log ;;
            2|02) _setting_dns ;;
            3|03) _setting_strategy ;;
            0|00) return ;;
            *) echo -e "\n  ${GREY}无效输入，请重试...${NC}"; sleep 1 ;;
        esac
    done
}
# --- 自动填充默认设置 (非交互式) ---
# 该函数由主脚本在初始化时调用，用于修复缺失的关键配置

_check_and_fill_defaults() {
    local modified=false

    # 1. 检查 Log 配置 (默认: Error)
    if ! jq -e '.log' "$CONFIG_FILE" >/dev/null 2>&1; then
        local default_log='{"level": "error", "timestamp": false}'
        _atomic_modify_json "$CONFIG_FILE" ".log = $default_log"
        _info "已自动应用默认日志设置: Error"
        modified=true
    fi

    # 2. 检查 DNS 配置 (默认: 国外优先 - 复用 _setting_dns 选项 01 的配置)
    if ! jq -e '.dns' "$CONFIG_FILE" >/dev/null 2>&1; then
        local default_dns='{
            "servers": [
                {"type": "udp", "tag": "bootstrap-v4", "server": "1.1.1.1", "server_port": 53},
                {"type": "https", "tag": "dns", "server": "cloudflare-dns.com", "path": "/dns-query", "domain_resolver": "bootstrap-v4"},
                {"type": "https", "tag": "doh-google", "server": "dns.google", "path": "/dns-query", "domain_resolver": "bootstrap-v4"},
                {"type": "https", "tag": "doh-quad9", "server": "dns.quad9.net", "path": "/dns-query", "domain_resolver": "bootstrap-v4"}
            ]
        }'
        _atomic_modify_json "$CONFIG_FILE" ".dns = $default_dns"
        _info "已自动应用默认 DNS 设置: 国外优先"
        modified=true
    fi

    # 3. 检查 Route 基础结构
    if ! jq -e '.route' "$CONFIG_FILE" >/dev/null 2>&1; then
         _atomic_modify_json "$CONFIG_FILE" '.route = {"final": "direct", "auto_detect_interface": true}'
         modified=true
    fi

    # 4. 检查 Route 策略 (默认: 优先 IPv6)
    if ! jq -e '.route.rules[] | select(.action == "resolve")' "$CONFIG_FILE" >/dev/null 2>&1; then
        local default_strategy='{
            "action": "resolve",
            "strategy": "prefer_ipv6",
            "disable_cache": false
        }'
        # 将默认策略插入到 rules 数组的最前面
        _atomic_modify_json "$CONFIG_FILE" ".route.rules = [$default_strategy] + (.route.rules // [])"
        _atomic_modify_json "$CONFIG_FILE" '.route.default_domain_resolver = "dns"'
        _info "已自动应用默认路由策略: 优先 IPv6"
        modified=true
    fi

    if [ "$modified" = true ]; then
        _success "核心配置自检完成: 已补全缺失的默认设置"
    fi
}
