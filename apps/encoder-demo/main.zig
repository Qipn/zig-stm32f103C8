//! 编码器 + 电机示例 —— 移植参考工程 `MiniBalance_HARDWARE/ENCODER` + `MOTOR`。
//!
//! 演示:
//!   * 初始化左右编码器（TIM2/PA0-PA1、TIM4/PB6-PB7）
//!   * 初始化电机 PWM（TIM1/PA8、PA11 + 方向脚 PB12~15）
//!   * 每 100ms 读一次编码器计数并显示，同时让电机小幅来回转动
//!
//! 现象（OLED）:
//!   * `L:` 左轮编码器计数，`R:` 右轮计数
//!   * 电机轻微来回转动 → 编码器计数正负变化
//!
//! 安全: PWM 幅度限制在 ±2000（满量程 7199），避免飞车。测试时最好架空车轮。
//!
//! 对照:
//!   Encoder_Init_TIM2/4()  -> encoder.initBoardEncoders()
//!   Read_Encoder()         -> enc.left.read() / enc.right.read()
//!   MiniBalance_PWM_Init() -> motor.initBoardMotor()

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const encoder = @import("encoder");
const motor = @import("motor");
const oled = @import("oled");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

/// 电机最大测试幅度（满量程 = motor.arr = 7199）。
const test_pwm: i32 = 2000;

fn showInt(disp: *oled.Oled, x: u8, y: u8, v: i32) void {
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    disp.showString(x, y, s);
}

pub fn main() !void {
    delay.init(8_000_000);

    var disp = oled.initOled();
    const enc = encoder.initBoardEncoders();
    const mot = motor.initBoardMotor();

    disp.showString(0, 0, "ENC + MOTOR");
    disp.showString(0, 16, "L:");
    disp.showString(0, 32, "R:");
    disp.refresh();

    var dir: i32 = 1;
    var tick: u32 = 0;

    while (true) {
        // 电机小幅来回转（方便观察编码器正负变化）
        mot.set(test_pwm * dir, test_pwm * dir);

        // 读编码器（读后清零 = 每周期脉冲数）
        const l = enc.left.read();
        const r = enc.right.read();

        // 清值区重画
        var x: u8 = 12;
        while (x < 120) : (x += 1) {
            var y: u8 = 16;
            while (y < 44) : (y += 1) disp.drawPoint(x, y, 0);
        }
        showInt(&disp, 12, 16, l);
        showInt(&disp, 12, 32, r);
        disp.refresh();

        tick += 1;
        if (tick % 10 == 0) dir = -dir; // 每 ~1s 换向

        delay.delayMs(100);
    }
}
