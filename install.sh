#!/usr/bin/env bash
set -euo pipefail

REPO="Zzz-IT/-Singbox-Maker-Z"
BRANCH="main"

INSTALL_DIR="/usr/local/share/singbox-maker-z"
BIN_LINK="/usr/local/bin/sb"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "请用 root 运行：sudo bash install.sh" >&2
    exit 1
  fi
}

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

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT

  # 使用 GitHub 源码归档下载（无需 releases/tag）
  local tar_url="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
  local tar_file="${tmp}/src.tar.gz"
  download "$tar_url" "$tar_file"

  tar -xzf "$tar_file" -C "$tmp"

  local src_dir="${tmp}/-Singbox-Maker-Z-${BRANCH}"

  # 必要文件校验（模块化版本）
  for f in singbox.sh utils.sh; do
    [[ -f "${src_dir}/${f}" ]] || { echo "缺少文件：${f}（请检查仓库内容）" >&2; exit 1; }
  done
  [[ -d "${src_dir}/lib" ]] || { echo "缺少目录：lib/（模块化版本必须）" >&2; exit 1; }

  # 原子覆盖安装：先复制到临时目录，再整体替换
  local new_dir="${tmp}/install.new"
  mkdir -p "$new_dir"

  # 只安装运行所需文件（避免把仓库杂项装进系统）
  cp -a "${src_dir}/singbox.sh" "$new_dir/"
  cp -a "${src_dir}/utils.sh" "$new_dir/"
  cp -a "${src_dir}/lib" "$new_dir/"

  # 备份旧安装（可选）
  if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf -- "${INSTALL_DIR}.bak" 2>/dev/null || true
    cp -a "$INSTALL_DIR" "${INSTALL_DIR}.bak" || true
  fi

  rm -rf -- "$INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  mv "$new_dir" "$INSTALL_DIR"

  chmod +x "${INSTALL_DIR}/singbox.sh"
  chmod +x "${INSTALL_DIR}/utils.sh" || true
  chmod +x "${INSTALL_DIR}/lib"/*.sh || true

  # sb 作为入口：软链到安装目录的 singbox.sh
  ln -sf "${INSTALL_DIR}/singbox.sh" "$BIN_LINK"

  echo "安装完成：${BIN_LINK} -> ${INSTALL_DIR}/singbox.sh"
  echo "运行：sb"
}

main "$@"
