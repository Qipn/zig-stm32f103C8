//! LED 闪烁 —— 用 SysTick 阻塞延时（移植自参考工程 delay.c）。
//!
//! 对比 led-blink：
//!   led-blink   用 hal.time.sleep_ms（依赖 microzig time 子系统）
//!   blink-systick 用 delay.delayMs（直接用 SysTick，自足、可靠）

const std = @import("std");
const microzig = @import("microzig");
const led = @import("led");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    // 对照参考工程 delay_init(): 系统时钟 8MHz（复位默认 HSI）
    delay.init(8_000_000);

    const my_led = led.initBoardLed();

    while (true) {
        my_led.toggle();
        delay.delayMs(500);
    }
}
