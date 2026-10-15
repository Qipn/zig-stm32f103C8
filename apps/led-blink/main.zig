//! LED blink —— 使用 led 驱动模块（PA4）。
//!
//! 对照参考工程:
//!   LED_Init()   -> led.initBoardLed()
//!   Led_Flash()  -> led_handle.toggle() 定时翻转
//!
//! 延时用 SysTick 阻塞延时（delay.delayMs），对应参考工程 SYSTEM/delay。
//! （不用 microzig 的 hal.time.sleep_ms —— 它依赖 time 子系统，易卡死。）

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
    // 对照参考工程 delay_init()
    delay.init(8_000_000);

    // 对照 LED_Init()：配置引脚（含 GPIO 时钟），拿到 LED 句柄
    const my_led = led.initBoardLed();

    while (true) {
        // 对照 Led_Flash()：每 500ms 翻转一次
        my_led.toggle();
        delay.delayMs(500);
    }
}
