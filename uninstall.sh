#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/usr/local/share/singbox-maker-z"
BIN_LINK="/usr/local/bin/sb"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请用 root 运行：sudo bash uninstall.sh" >&2
  exit 1
fi

rm -rf -- "$INSTALL_DIR"
rm -f -- "$BIN_LINK"

echo "已卸载：$INSTALL_DIR 并移除入口 $BIN_LINK"
