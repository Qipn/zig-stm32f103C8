//! 按键 FIFO 示例 —— 移植自参考工程的 `bsp_key.c` 算法。
//!
//! 架构对照参考工程:
//!   * **TIM3 中断每 10ms** 调 `scanner.scan()`（对照 bsp_KeyScan10ms 由 systick 调用）
//!   * 主循环用 `scanner.getKey()` 从 FIFO 取事件（对照 bsp_GetKey）
//!   * 每键支持: 按下(DOWN) / 弹起(UP) / 长按(LONG) / 长按后连发
//!
//! 引脚: 按键 **PA5**；LED 反馈用 **PA4**；OLED 显示 PB3/4/5 + PA15。
//!
//! 现象:
//!   * 按下 → OLED 计 D 数 +1，LED 亮
//!   * 弹起 → OLED 计 U 数 +1，LED 灭
//!   * 长按 1s → OLED 计 L 数 +1，之后进入连发（D 数持续 +1）
//!
//! 注: 现在 OLED 不再占用 TIM2，按键扫描仍用 TIM3（不与外设冲突）。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const key_scan = @import("key_scan");
const oled = @import("oled");
const led = @import("led");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

const timer = hal.timer.GPTimer.init(.TIM3);

/// 中断与主循环共享的扫描器（volatile 语义由微控制器内存模型保证；
/// 中断只写 FIFO，主循环只读，临界区极短，这里依赖单核顺序一致）。
var scanner: key_scan.BoardKey = undefined;

/// 主循环侧的事件计数（由从 FIFO 取出的事件累加）。
var cnt_down: u32 = 0;
var cnt_up: u32 = 0;
var cnt_long: u32 = 0;

/// 注册 TIM3 中断处理程序：每 10ms 扫描一次按键。
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .TIM3 = .{ .c = isrTim3 } },
    .overwrite_hal_interrupts = true,
};

fn isrTim3() callconv(.c) void {
    timer.clear_interrupts();
    scanner.scan(); // 对照 bsp_KeyScan10ms()
}

pub fn main() !void {
    // SysTick 延时（OLED 复位延时用它，不再依赖 hal.time / TIM2）
    delay.init(8_000_000);

    const my_led = led.initBoardLed();
    var disp = oled.initOled();

    // 初始化按键扫描器（TIM3 中断里会用到，故先于启动定时器）
    scanner = key_scan.initBoardKey();

    // TIM3: 8MHz, PSC=7999 → 1kHz, ARR=9 → 10ms 中断一次
    hal.rcc.enable_clock(.TIM3);
    timer.timer_general_config(.{
        .prescaler = 7999,
        .auto_reload = 9,
        .enable_update_interrupt = true,
        .counter_mode = .up,
    });
    // NVIC 里使能 TIM3 中断（优先级分组 g2 下占用最低）
    microzig.cpu.interrupt.set_priority(.TIM3, @enumFromInt(15));
    microzig.cpu.interrupt.enable(.TIM3);
    timer.start();
    microzig.cpu.interrupt.enable_interrupts();

    // 初始界面
    disp.showString(0, 0, "KEY FIFO (bsp_key)");
    disp.showString(0, 16, "D:");
    disp.showString(0, 32, "U:");
    disp.showString(0, 48, "L:");
    disp.refresh();

    var dirty = false;

    while (true) {
        // 从 FIFO 取事件（对照 bsp_GetKey）
        while (scanner.getKey()) |ev| {
            switch (ev.event) {
                .down => {
                    cnt_down +%= 1;
                    my_led.on();
                },
                .up => {
                    cnt_up +%= 1;
                    my_led.off();
                },
                .long => {
                    cnt_long +%= 1;
                    my_led.toggle();
                },
            }
            dirty = true;
        }

        if (dirty) {
            disp.showNumber(18, 16, cnt_down, 6, .font_6x12);
            disp.showNumber(18, 32, cnt_up, 6, .font_6x12);
            disp.showNumber(18, 48, cnt_long, 6, .font_6x12);
            disp.refresh();
            dirty = false;
        }
    }
}
