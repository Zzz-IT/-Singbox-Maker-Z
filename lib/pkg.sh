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
            _info "检测到缺少依赖，正在以极低内存模式更新软件源..."
            
            # 写入临时低内存 apt 配置
            local apt_tmp_conf="/etc/apt/apt.conf.d/99lowmemory"
            echo 'APT::Cache-Start 0;' > "$apt_tmp_conf"
            echo 'Acquire::Languages "none";' >> "$apt_tmp_conf" # 禁用多语言翻译包下载
            echo 'Acquire::PDiffs "false";' >> "$apt_tmp_conf"   # 降低增量更新的 CPU 和内存开销
            
            # 清理旧的缓存列表，腾出内存和磁盘空间
            rm -rf /var/lib/apt/lists/* 2>/dev/null || true
            
            $TIMEOUT_CMD apt-get update -qq >/dev/null 2>&1 || true
            # 增加 --no-install-recommends 参数，禁止安装非必须的推荐包
            DEBIAN_FRONTEND=noninteractive $TIMEOUT_CMD apt-get install -y --no-install-recommends $pkgs >/dev/null 2>&1
            
            # 用完即删，保持系统干净
            rm -f "$apt_tmp_conf"
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
