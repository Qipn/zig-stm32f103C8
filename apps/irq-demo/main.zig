//! 中断 + OLED 联动 —— TIM2 中断维护计时，主循环显示到 OLED。
//!
//! 验证参考工程 `SYSTEM/sys` 的中断机制:
//!   MY_NVIC_PriorityGroupConfig() -> nvic.priorityGroupConfig()
//!   MY_NVIC_Init()                -> nvic.init()
//!   TIM2 中断服务程序             -> isrTim2() (注册到 microzig_options)
//!
//! 中断与主循环通过**共享变量**通信（对照参考工程的全局变量风格）:
//!   * ISR 每秒递增 `seconds`、翻转 LED
//!   * 主循环读 `seconds`，刷新 OLED 显示运行时间
//!
//! 现象: LED 约 0.5Hz 闪；OLED 显示运行秒数并递增。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const led = @import("led");
const oled = @import("oled");
const nvic = @import("nvic");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

const timer = hal.timer.GPTimer.init(.TIM3);
var my_led = led.board_led;

/// 中断与主循环共享的状态（volatile: 中断里改，主循环读）。
var seconds: u32 = 0;

/// 注册 TIM3 中断处理程序。
/// 注意: 不用 TIM2 —— 它被 microzig 的 time 子系统占用（OLED 延时用）。
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .TIM3 = .{ .c = isrTim3 } },
    .overwrite_hal_interrupts = true,
};

/// TIM3 中断服务程序（每秒一次）: 计时 + 翻转 LED。
fn isrTim3() callconv(.c) void {
    timer.clear_interrupts();
    seconds +%= 1;
    my_led.toggle();
}

/// 简易十进制打印（返回写入的字节数）。
fn printNum(disp: *oled.Oled, x: u8, y: u8, v: u32, len: u8) void {
    disp.showNumber(x, y, v, len, .font_6x12);
}

pub fn main() !void {
    // NVIC 优先级分组（对照 MY_NVIC_PriorityGroupConfig(2)）
    nvic.priorityGroupConfig(.g2);

    // SysTick 延时（主循环用）
    delay.init(8_000_000);

    // LED
    my_led = led.initBoardLed();

    // OLED（其驱动内部用 delay.delayMs，需先 delay.init）
    var disp = oled.initOled();

    // TIM3: 8MHz, PSC=7999→1kHz, ARR=999→1Hz(每秒中断一次)
    // 用 TIM3 而非 TIM2: TIM2 已被 time 子系统占用。
    hal.rcc.enable_clock(.TIM3);
    timer.timer_general_config(.{
        .prescaler = 7999,
        .auto_reload = 999,
        .enable_update_interrupt = true,
        .counter_mode = .up,
    });

    // 使能 TIM3 中断（对照 MY_NVIC_Init）
    nvic.init(2, 0, .TIM3, .g2);

    // 启动定时器 + 全局中断
    timer.start();
    nvic.enableInterrupts();

    // 初始界面
    disp.showString(0, 0, "IRQ + OLED");
    disp.showString(0, 16, "uptime (s):");
    disp.refresh();

    // 主循环：显示中断维护的秒数
    while (true) {
        // 清掉数字区域再重画，避免残影
        var x: u8 = 0;
        while (x < 60) : (x += 1) {
            var yy: u8 = 32;
            while (yy < 44) : (yy += 1) disp.drawPoint(x, yy, 0);
        }
        printNum(&disp, 0, 32, seconds, 6);
        disp.refresh();
        delay.delayMs(200);
    }
}
