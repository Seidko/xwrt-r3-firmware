#!/usr/bin/env bash
# =============================================================================
# X-Wrt R3 云编译 / 本地编译统一脚本
#
# 用法（在仓库根目录执行）：
#   bash scripts/build.sh prepare   # 克隆源码 + 注入 feeds + 生成 .config + defconfig
#   bash scripts/build.sh make      # make download + 全量编译（可配合 ccache 复用）
#   bash scripts/build.sh all       # prepare + make 一键
#
# 环境变量（均有默认值）：
#   XWRT_REPO   X-Wrt 源码地址            默认 https://github.com/x-wrt/x-wrt.git
#   XWRT_REF    ref（分支名或完整 SHA）    默认 master
#   SOURCE_DIR  源码落盘目录              默认 ./source
#   CONFIG_SEED 种子配置路径              默认 ./config/r3-minimal.seed
#   JOBS        并行编译核数              默认 nproc
#
# 说明：
#   - 本脚本应在 Linux/macOS 上运行（OpenWrt 不支持 Windows 原生编译）。
#     GitHub Actions 已在 ubuntu 上调用它；本地想复现请用 WSL/Ubuntu。
#   - 每次执行都基于干净 clone + 本仓库 overlay，保证可复现、可审计。
# =============================================================================
set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TOP"

XWRT_REPO="${XWRT_REPO:-https://github.com/x-wrt/x-wrt.git}"
XWRT_REF="${XWRT_REF:-master}"
SOURCE_DIR="${SOURCE_DIR:-$TOP/source}"
CONFIG_SEED="${CONFIG_SEED:-$TOP/config/r3-minimal.seed}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

log() { printf '\n\033[1;32m[build] %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[build] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# prepare：克隆/更新 X-Wrt 源码 -> 注入 helloworld feed -> feeds install -> .config
# ---------------------------------------------------------------------------
prepare() {
  log "1/5 准备 X-Wrt 源码 (ref=${XWRT_REF})"
  if [ ! -d "$SOURCE_DIR/.git" ]; then
    mkdir -p "$SOURCE_DIR"
    git init -q "$SOURCE_DIR"
    git -C "$SOURCE_DIR" remote add origin "$XWRT_REPO"
    if [[ "$XWRT_REF" =~ ^[0-9a-f]{40}$ ]]; then
      # ref 是完整 commit SHA：按 SHA 拉取
      git -C "$SOURCE_DIR" fetch -q --depth 1 origin "$XWRT_REF"
      git -C "$SOURCE_DIR" checkout -q FETCH_HEAD
      git -C "$SOURCE_DIR" switch -c build 2>/dev/null || true
    else
      git -C "$SOURCE_DIR" fetch -q --depth 1 origin "$XWRT_REF"
      git -C "$SOURCE_DIR" checkout -q -B build FETCH_HEAD
    fi
  else
    log "   源码目录已存在，跳过 clone（若需强制重拉请删除 ${SOURCE_DIR}）"
  fi

  log "2/5 注入 helloworld feed（fw876/helloworld = luci-app-ssr-plus 现役仓库）"
  local fc="$SOURCE_DIR/feeds.conf.default"
  grep -q '^src-git[[:space:]]*helloworld' "$fc" 2>/dev/null || \
    printf '\n# Added by xwrt-r3-firmware overlay (2026-09): luci-app-ssr-plus feed\nsrc-git helloworld https://github.com/fw876/helloworld.git\n' >> "$fc"
  cat "$fc"

  log "3/5 feeds update + install"
  ( cd "$SOURCE_DIR" && ./scripts/feeds update -a )
  # 常规 feed 全装后，再强制装 helloworld（其自带的 shadowsocks-*/microsocks 等必须覆盖）
  ( cd "$SOURCE_DIR" && ./scripts/feeds install -a )
  ( cd "$SOURCE_DIR" && ./scripts/feeds install -a -f -p helloworld || true )

  log "4/5 去重：凡 helloworld 提供的包，从其它 feed 目录中移除（保证用 helloworld 版本）"
  local hw_dir="$SOURCE_DIR/package/feeds/helloworld"
  if [ -d "$hw_dir" ]; then
    for d in "$SOURCE_DIR"/package/feeds/*/; do
      local feed
      feed="$(basename "$d")"
      [ "$feed" = "helloworld" ] && continue
      for p in "$hw_dir"/*/; do
        local pname
        pname="$(basename "$p")"
        if [ -e "$d/$pname" ]; then
          echo "  [dedupe] ${feed}/${pname} -> 使用 helloworld 版本"
          rm -rf "$d/$pname"
        fi
      done
    done
  fi

  log "5/5 写入种子配置并 make defconfig"
  [ -f "$CONFIG_SEED" ] || die "找不到种子配置: $CONFIG_SEED"
  cp "$CONFIG_SEED" "$SOURCE_DIR/.config"
  ( cd "$SOURCE_DIR" && make defconfig )

  echo "===== defconfig 完成：关键项预览 ====="
  grep -E '^(CONFIG_TARGET_ramips|CONFIG_PACKAGE_luci-app-ssr-plus|CONFIG_PACKAGE_dnsmasq|CONFIG_PACKAGE_firewall)' \
    "$SOURCE_DIR/.config" | sort | uniq || true
}

# ---------------------------------------------------------------------------
# make：下载源码 + 编译
# ---------------------------------------------------------------------------
do_make() {
  [ -d "$SOURCE_DIR/.git" ] || die "先执行 prepare（缺少 $SOURCE_DIR）"

  log "下载全部依赖源码（含 Rust 相关，首次较久）"
  ( cd "$SOURCE_DIR" && make -j"$JOBS" download )

  log "开始编译：JOBS=${JOBS}，日志写入 build.log"
  if ! ( cd "$SOURCE_DIR" && make -j"$JOBS" V=s > "$TOP/build.log" 2>&1 ); then
    echo "===== 编译失败，build.log 末尾 200 行 ====="
    tail -200 "$TOP/build.log" || true
    die "编译失败，详见 $TOP/build.log"
  fi

  log "编译完成，产物："
  ls -la "$SOURCE_DIR"/bin/targets/ramips/mt7620/ | grep -E 'xiaomi_miwifi-r3|sha256sums' || true
}

case "${1:-all}" in
  prepare) prepare ;;
  make)    do_make ;;
  all)     prepare && do_make ;;
  *)       echo "用法: $0 {prepare|make|all}"; exit 1 ;;
esac
