//! 编码器独立测试 —— 只读编码器，不驱动电机（便于手动转轮验证）。
//!
//! 对照参考工程 `MiniBalance_HARDWARE/ENCODER`:
//!   Encoder_Init_TIM2()  -> 左轮 TIM2 (PA0/PA1)
//!   Encoder_Init_TIM4()  -> 右轮 TIM4 (PB6/PB7)
//!   Read_Encoder()       -> 每周期读计数并清零
//!
//! 现象（OLED）:
//!   * `L:` 左轮本周期计数，`R:` 右轮本周期计数
//!   * **用手正转/反转轮子** → 数值随转速正负变化；停转 → 归零
//!   * `Ltot:` / `Rtot:` 累计计数（不清零，用于确认方向）
//!
//! 用法: 上电后用手（或让电机空转）转动轮子，观察 L/R 数值。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const encoder = @import("encoder");
const oled = @import("oled");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

fn showInt(disp: *oled.Oled, x: u8, y: u8, v: i32) void {
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    disp.showString(x, y, s);
}

pub fn main() !void {
    delay.init(8_000_000);

    var disp = oled.initOled();
    const enc = encoder.initBoardEncoders();

    disp.showString(0, 0, "ENCODER test");
    disp.showString(0, 16, "L:");
    disp.showString(0, 32, "R:");
    disp.refresh();

    var total_l: i32 = 0;
    var total_r: i32 = 0;

    while (true) {
        // 每周期读（读后自动清零 = 本周期脉冲数）
        const l = enc.left.read();
        const r = enc.right.read();
        total_l += l;
        total_r += r;

        // 清值区重画
        var x: u8 = 12;
        while (x < 120) : (x += 1) {
            var y: u8 = 16;
            while (y < 44) : (y += 1) disp.drawPoint(x, y, 0);
        }
        showInt(&disp, 12, 16, l);
        showInt(&disp, 12, 32, r);
        disp.refresh();

        delay.delayMs(100);
    }
}
