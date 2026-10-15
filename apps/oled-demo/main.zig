//! OLED 显示示例 —— SSD1306 128x64, 软件 SPI。
//!
//! 引脚（与参考工程 MiniBalance_HARDWARE/OLED 一致）:
//!   RST=PB3, DC=PA15, SCL=PB5, SDA=PB4
//!
//! 诊断: 先让 LED 心跳闪烁（证明 main 在跑），再初始化 OLED。
//!   - LED 闪 + 屏亮  -> 成功
//!   - LED 闪 + 屏黑  -> 程序正常，问题在 OLED 硬件/接线/协议
//!   - LED 不闪       -> 卡在启动/时钟

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const oled = @import("oled");
const led = @import("led");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    // SysTick 延时（OLED 复位延时也用这个，不再依赖 hal.time / TIM2）
    delay.init(8_000_000);

    // 心跳 LED
    const heartbeat = led.initBoardLed();

    // 初始化 OLED（含 JTAG 释放 + GPIO 时钟 + 引脚配置 + SSD1306 初始化 + 清屏）
    var disp = oled.initOled();

    disp.showString(0, 0, "car-zig OLED");
    disp.showString(0, 16, "SSD1306 128x64");
    disp.showString(0, 32, "Port from oled.c");
    disp.refresh();

    var n: u32 = 0;
    while (true) {
        // LED 心跳（证明程序在跑）
        heartbeat.toggle();
        delay.delayMs(500);

        // 每秒刷新一次计数
        n +%= 1;
        if (n % 2 == 0) {
            disp.showNumber(80, 48, n / 2, 6, .font_6x12);
            disp.refresh();
        }
    }
}
