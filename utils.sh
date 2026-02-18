#!/usr/bin/env bash

# utils.sh (模块加载器 + 兼容层)
# - 负责加载 lib/ 下的模块
# - 对外保留旧版函数名，尽量不要求主脚本改动

UTILS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_DIR="${UTILS_DIR}/lib"

# 基础模块加载（顺序重要：log -> pkg -> system -> 其它）
# shellcheck source=/dev/null
source "${LIB_DIR}/log.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/pkg.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/system.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/url.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/net.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/json.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/mem.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/service.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/iptables.sh"

# --- [新增] 加载高级设置模块 ---
# shellcheck source=/dev/null
source "${LIB_DIR}/settings.sh"

# 兼容：旧版曾 export 了这些函数
export -f _check_root _detect_init_system _install_yq _save_iptables_rules
