//! 按键示例 —— 移植参考工程 `MiniBalance_HARDWARE/KEY` (key.c)。
//!
//! 用 `KEY_Scan` 状态机（key.keyScan）识别 **单击 / 双击 / 长按**，
//! 显示到 OLED，并用板载 LED 作反馈。
//!
//! 引脚: 按键 **PA5**（上拉输入，按下为低），与 LED(PA4)、OLED(PB3/4/5,PA15) 不冲突。
//!
//! 现象:
//!   * 单击 → OLED 累加 "S" 计数，LED 闪一下
//!   * 双击 → OLED 累加 "D" 计数，LED 闪两下
//!   * 长按 → OLED 累加 "L" 计数，LED 亮片刻
//!
//! 用法: 上电后按动 PA5 按键即可。
//!
//! 说明: OLED 驱动内部用 `delay.delayMs`（SysTick），故先 `delay.init(系统时钟)`。
//! 主循环用 SysTick 定周期扫描，频率 100Hz（每 10ms 一次）。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const key = @import("key");
const oled = @import("oled");
const led = @import("led");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

/// 扫描频率（Hz）：每 10ms 调一次 keyScan。
const scan_hz: u16 = 100;
/// 数字滤波次数（消抖）。
const filter_times: u16 = 2;

pub fn main() !void {
    // SysTick 延时（也用于主循环定周期；OLED 复位延时同样用它）
    delay.init(8_000_000);

    const my_led = led.initBoardLed();
    var disp = oled.initOled();
    var btn = key.initBoardKey();

    var n_single: u32 = 0;
    var n_double: u32 = 0;
    var n_long: u32 = 0;

    disp.showString(0, 0, "KEY: PA5");
    disp.showString(0, 16, "S:");
    disp.showString(0, 32, "D:");
    disp.showString(0, 48, "L:");
    disp.refresh();

    while (true) {
        // 周期扫描（100Hz → 每 10ms 一次）
        const ev = btn.keyScan(scan_hz, filter_times);

        switch (ev) {
            .single => {
                n_single +%= 1;
                my_led.on();
                delay.delayMs(20);
                my_led.off();
            },
            .double => {
                n_double +%= 1;
                var i: u8 = 0;
                while (i < 2) : (i += 1) {
                    my_led.on();
                    delay.delayMs(20);
                    my_led.off();
                    delay.delayMs(20);
                }
            },
            .long => {
                n_long +%= 1;
                my_led.on();
                delay.delayMs(300);
                my_led.off();
            },
            .stateless => {},
        }

        // 有事件时刷新计数显示
        if (ev != .stateless) {
            disp.showNumber(18, 16, n_single, 5, .font_6x12);
            disp.showNumber(18, 32, n_double, 5, .font_6x12);
            disp.showNumber(18, 48, n_long, 5, .font_6x12);
            disp.refresh();
        }

        // 定周期 10ms（扫描频率由这里保证；上面动作耗时会略拖慢，
        // 但双击/长按阈值有宽裕，不影响识别）。
        delay.delayMs(10);
    }
}
