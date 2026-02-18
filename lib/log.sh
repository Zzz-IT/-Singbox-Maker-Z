#!/usr/bin/env bash

# 颜色定义
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

_info()    { printf '%b\n' "${CYAN}[信息] $*${NC}"; }
_success() { printf '%b\n' "${GREEN}[成功] $*${NC}"; }
_warn()    { printf '%b\n' "${YELLOW}[注意] $*${NC}"; }
_warning() { _warn "$@"; }
_error()   { printf '%b\n' "${RED}[错误] $*${NC}"; }

export -f _info _success _warn _warning _error
