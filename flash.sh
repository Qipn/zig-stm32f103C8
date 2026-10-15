#!/usr/bin/env bash
# ============================================================
# STM32 + microzig 烧录脚本（car-zig）
# ------------------------------------------------------------
# 用法（在任意目录均可执行本脚本）:
#   ./flash.sh                  # 构建 + 烧录默认 app
#   ./flash.sh led-blink        # 构建 + 烧录指定 app
#   ./flash.sh --no-build       # 跳过构建，只烧录已存在的固件
#
# 设计要点:
#   * **构建始终以普通用户执行**（zig 缓存属主必须是本人，
#     否则会污染 .zig-cache 导致权限错误）。
#   * **仅烧录步骤**在检测到 ST-Link 无权限时自动 sudo。
#     修复方向: 应用 nixos 配置后用户属于 plugdev, 即可免 sudo。
#   * 通过 flake.nix 提供 Zig 0.17, 并修正 socks 代理。
# ============================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

DEFAULT_APP="led-blink"
DO_BUILD=1
APP=""

# ---------- 解析参数 ----------
for arg in "$@"; do
    case "$arg" in
        --no-build|-n) DO_BUILD=0 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        -*) echo "未知选项: $arg" >&2; exit 1 ;;
        *)  APP="$arg" ;;
    esac
done
APP="${APP:-$DEFAULT_APP}"

ELF="$APP_DIR/zig-out/firmware/$APP.elf"
LOG_DIR="$APP_DIR/tmp"
mkdir -p "$LOG_DIR"

# ---------- 颜色 ----------
if [ -t 1 ]; then
    CYN=$'\033[36m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
else
    CYN=''; GRN=''; YEL=''; RED=''; RST=''
fi
info() { echo "${CYN}[信息]${RST} $*"; }
ok()   { echo "${GRN}[成功]${RST} $*"; }
warn() { echo "${YEL}[警告]${RST} $*"; }
err()  { echo "${RED}[错误]${RST} $*" >&2; }

# ---------- 1. 构建（普通用户，绝不用 sudo）----------
if [ "$DO_BUILD" -eq 1 ]; then
    info "构建 $APP ..."
    nix develop "path:${APP_DIR}#" -c bash -c '
        case "${ALL_PROXY:-}" in
            socks://*) export ALL_PROXY="socks5://${ALL_PROXY#socks://}" ;;
        esac
        exec zig build "$@"
    ' _ "$APP"
    ok "构建完成"
fi

# ---------- 2. 检查固件是否存在 ----------
if [ ! -f "$ELF" ]; then
    err "找不到固件: $ELF"
    err "请先构建（去掉 --no-build），或确认 app 名是否正确。"
    exit 1
fi
info "固件: $ELF"

# ---------- 3. 组装 openocd 烧录命令 ----------
OPENOCD_ARGS=(
    -f interface/stlink.cfg
    -f target/stm32f1x.cfg
    -c "program {$ELF} verify reset exit"
)

# ---------- 4. 烧录（必要时提权，但仅限 openocd）----------
# 日志写 tmp/, 每次运行用时间戳+后缀, 避免 root 覆盖本人文件
log_path() { echo "$LOG_DIR/flash-$(date +%Y%m%d-%H%M%S)-$$.log"; }
LOG="$(log_path)"

info "烧录中（OpenOCD + ST-Link）..."
set +e
openocd "${OPENOCD_ARGS[@]}" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e

# 若因 USB 权限失败，用 sudo 重试（只提权这一步）
if [ "$RC" -ne 0 ] && grep -qiE "LIBUSB_ERROR_ACCESS|access error|permission" "$LOG"; then
    warn "ST-Link 无访问权限，尝试用 sudo 重试（仅烧录步骤）..."
    LOG="$(log_path)"
    set +e
    sudo openocd "${OPENOCD_ARGS[@]}" 2>&1 | tee "$LOG"
    RC=${PIPESTATUS[0]}
    set -e
    # sudo 生成的日志归还属主
    chown "$(id -u):$(id -g)" "$LOG" 2>/dev/null || true
fi

if [ "$RC" -eq 0 ]; then
    ok "烧录完成: $APP"
else
    err "烧录失败（退出码 $RC）"
    warn "若为权限问题，应用 nixos 配置后可免 sudo:"
    echo "    sudo nixos-rebuild switch --flake /etc/nixos#wecom"
    exit "$RC"
fi
