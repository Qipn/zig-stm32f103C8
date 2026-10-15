#!/usr/bin/env bash
# ============================================================
# STM32 + microzig 构建脚本（car-zig）
# ------------------------------------------------------------
# 用法（在任意目录均可执行本脚本）:
#   ./build.sh                  # 构建默认 app（ReleaseSmall 由 zig 默认）
#   ./build.sh led-blink        # 构建指定 app
#   ./build.sh -Doptimize=ReleaseSmall
#
# 说明:
#   * **始终以普通用户构建**（zig 缓存属主必须是自己）。
#     烧录请用 ./flash.sh（会按需自动提权 openocd）。
#   * 通过项目内 flake.nix 提供 Zig 0.17（nixpkgs 尚无）。
#   * 自动把 socks:// 代理修正为 socks5://（zig 0.17 要求）。
#   * 依赖已缓存后，构建无需联网。
# ============================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "[错误] 请勿用 sudo/root 运行构建脚本——会污染 .zig-cache 属主。" >&2
    echo "       烧录用 ./flash.sh；构建用普通用户执行本脚本。" >&2
    exit 1
fi

ARGS=("$@")
[ "${#ARGS[@]}" -eq 0 ] && ARGS=(build) || ARGS=(build "${ARGS[@]}")

# 在 nix 开发环境中执行，并修正代理环境变量
nix develop "path:${APP_DIR}#" -c bash -c '
    case "${ALL_PROXY:-}" in
        socks://*) export ALL_PROXY="socks5://${ALL_PROXY#socks://}" ;;
    esac
    exec zig "$@"
' _ "${ARGS[@]}"

echo "==> 产物: $APP_DIR/zig-out/firmware/"
