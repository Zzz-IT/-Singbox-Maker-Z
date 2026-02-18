#!/usr/bin/env bash

_get_mem_limit() {
    local total_mem_mb
    # 增加对 free 命令缺失的兼容（虽然通常都有）
    if command -v free >/dev/null 2>&1; then
        total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    else
        # 备用方案：从 /proc/meminfo 读取
        total_mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    fi

    # 逻辑优化：
    # 1. 如果内存 > 64MB，预留 40MB 给系统
    # 2. 如果内存 <= 64MB，只预留 20MB，极限压缩
    # 3. 保证 sing-box 至少有 10MB 配额
    local mem_limit_mb
    if [ "$total_mem_mb" -gt 64 ]; then
        mem_limit_mb=$(( total_mem_mb - 40 ))
    else
        mem_limit_mb=$(( total_mem_mb - 20 ))
    fi

    # 兜底：防止算出负数或过小的值
    if [ "$mem_limit_mb" -lt 10 ]; then
        mem_limit_mb=10
    fi
    
    printf '%s' "$mem_limit_mb"
}
export -f _get_mem_limit
