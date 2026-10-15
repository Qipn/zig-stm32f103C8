#!/usr/bin/env bash
# ============================================================
# 反复重试烧录（car-zig）
# ------------------------------------------------------------
# 用途: 当 ST-Link 报 "init mode failed (unable to connect to
#       the target)"（SWD 同步失败）时，反复尝试，给用户留时间
#       **按板子复位键抢连接**。第 N 次成功即可。
#
# 用法:
#   ./tools/flash-retry.sh              # 默认 led-blink
#   ./tools/flash-retry.sh key-demo     # 指定 app
#   ./tools/flash-retry.sh key-demo 60  # 最多尝试 60 次（默认 30）
#   ./tools/flash-retry.sh key-demo 60 --fast   # 用高速 SWD（默认已是低速）
#
# 默认（低速模式）:
#   * adapter speed 100  : SWD 时钟降到 100kHz，连接更稳（默认 1000kHz 易掉线）
#   * connect_assert_srst: 连接时先拉住复位再连，抢 SWD 更可靠
#   实测这套参数对间歇性 SWD 连接成功率最高。
#
# 说明:
#   * 需先构建好固件（zig-out/firmware/<app>.elf）。
#     可先 `./build.sh <app>`，或本脚本成功后不再构建。
#   * 仅烧录步骤用 sudo（若普通用户无 USB 权限）。
#   * 运行期间请**反复轻按板子 RESET**，成功率最高。
# ============================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR"

APP="led-blink"
MAX_RETRY=30
SLOW=1

# 位置参数: <app> [retry] ，另可任选 --fast
pos=0
for arg in "$@"; do
    case "$arg" in
        --fast) SLOW=0 ;;
        --slow) SLOW=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        -*)
            echo "[错误] 未知选项: $arg" >&2
            exit 1
            ;;
        *)
            pos=$((pos + 1))
            if [ "$pos" -eq 1 ]; then
                APP="$arg"
            elif [ "$pos" -eq 2 ]; then
                MAX_RETRY="$arg"
            fi
            ;;
    esac
done

ELF="$APP_DIR/zig-out/firmware/$APP.elf"

if [ ! -f "$ELF" ]; then
    echo "[错误] 找不到固件: $ELF" >&2
    echo "       请先构建: ./build.sh $APP" >&2
    exit 1
fi

# ---------- 组装 openocd 参数 ----------
OPENOCD_ARGS=(
    -f interface/stlink.cfg
    -f target/stm32f1x.cfg
)

if [ "$SLOW" -eq 1 ]; then
    # 低速 + 连接时拉住复位，显著提升间歇性 SWD 的成功率
    OPENOCD_ARGS+=(-c "adapter speed 100")
    OPENOCD_ARGS+=(-c "reset_config srst_only srst_nogate connect_assert_srst")
else
    OPENOCD_ARGS+=(-c "adapter speed 1000")
fi

OPENOCD_ARGS+=(-c "program {$ELF} verify reset exit")

echo "[信息] app=$APP  最多尝试 $MAX_RETRY 次  模式=$([ "$SLOW" -eq 1 ] && echo '低速(默认)' || echo '高速')"
echo "[信息] 运行期间请反复轻按板子 RESET 键以抢 SWD 连接"

i=1
while [ "$i" -le "$MAX_RETRY" ]; do
    echo "=== attempt $i/$MAX_RETRY ==="
    out="$(sudo openocd "${OPENOCD_ARGS[@]}" 2>&1)"

    # 摘要：只挑关键行
    echo "$out" | grep -E "init mode|Target voltage|halted|Wrote|Verified|Programming (Started|Finished)|Error"

    # 判断成功: 只看日志里的 "Verified OK"，**不看退出码**。
    # 原因: 间歇性 SWD 连接下，固件可能已烧录+校验成功，
    #       但在最后的 reset/shutdown 阶段又掉线，导致 openocd 退出码非 0。
    if echo "$out" | grep -q "Verified OK"; then
        echo "=== 成功: $APP (已烧录并校验) ==="
        exit 0
    fi

    i=$((i + 1))
    sleep 1
done

echo "=== 失败: 尝试 $MAX_RETRY 次仍无法连接 ===" >&2
echo "    可增大次数: ./tools/flash-retry.sh $APP 100" >&2
echo "    或全片擦除救援: sudo st-flash --connect-under-reset erase" >&2
exit 1
