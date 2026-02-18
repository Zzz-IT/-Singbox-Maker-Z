#!/usr/bin/env bash
set -euo pipefail

REPO="Zzz-IT/-Singbox-Maker-Z"
BRANCH="main"

INSTALL_DIR="/usr/local/share/singbox-maker-z"
BIN_LINK="/usr/local/bin/sb"

tmp_dir=""  # 给 -u 一个安全默认值，避免未定义

cleanup() {
  if [[ -n "${tmp_dir:-}" && -d "${tmp_dir:-}" ]]; then
    rm -rf -- "${tmp_dir}"
  fi
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "请用 root 运行：sudo bash install.sh" >&2
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

download() {
  local url="$1"
  local out="$2"

  if have_cmd curl; then
    curl -LfsS "$url" -o "$out"
  elif have_cmd wget; then
    wget -q "$url" -O "$out"
  else
    echo "缺少下载工具：curl 或 wget" >&2
    exit 1
  fi
}

main() {
  need_root

  tmp_dir="$(mktemp -d)"

  local tar_url="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
  local tar_file="${tmp_dir}/src.tar.gz"
  download "$tar_url" "$tar_file"

  tar -xzf "$tar_file" -C "$tmp_dir"

  local src_dir="${tmp_dir}/-Singbox-Maker-Z-${BRANCH}"

  # 校验必需文件/目录（模块化必须有 lib）
  [[ -f "${src_dir}/singbox.sh" ]] || { echo "缺少文件：singbox.sh（请检查仓库）" >&2; exit 1; }
  [[ -f "${src_dir}/utils.sh" ]]   || { echo "缺少文件：utils.sh（请检查仓库）" >&2; exit 1; }
  [[ -d "${src_dir}/lib" ]]        || { echo "缺少目录：lib/（请检查仓库）" >&2; exit 1; }

  local new_dir="${tmp_dir}/install.new"
  mkdir -p "$new_dir"
  cp -a "${src_dir}/." "$new_dir/"

  # 备份旧安装（可选）
  if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf -- "${INSTALL_DIR}.bak" 2>/dev/null || true
    cp -a "$INSTALL_DIR" "${INSTALL_DIR}.bak" || true
  fi

  rm -rf -- "$INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  mv "$new_dir" "$INSTALL_DIR"

  chmod +x "${INSTALL_DIR}/singbox.sh"
  ln -sf "${INSTALL_DIR}/singbox.sh" "$BIN_LINK"

  echo "安装完成：${BIN_LINK} -> ${INSTALL_DIR}/singbox.sh"
  echo "运行：sb"
}

main "$@"
