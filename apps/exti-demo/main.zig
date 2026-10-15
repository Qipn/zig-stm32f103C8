//! EXTI + MPU6050 INT 示例 —— 验证「MPU6050 data-ready 中断 → PA12 下降沿 → EXTI 计数」。
//!
//! 移植参考工程 `MiniBalance_HARDWARE/EXTI` (exti.c): PA12 上拉输入 + 下降沿中断。
//!
//! 链路:
//!   1. 初始化 MPU6050（软件 I2C）
//!   2. `setDataReadyRate100hz()` → 采样率 100Hz
//!   3. `enableDataReadyInt(push_pull=true, active_low=true, latch=false)`
//!      → INT 脚每 10ms 输出一个低脉冲（下降沿）
//!   4. PA12 配下降沿 EXTI + NVIC EXTI15_10 中断
//!   5. ISR 每次清 pending 并计数
//!
//! 现象（OLED）: `irq:` 计数约每 10ms +1（≈ 每秒 +100）。
//!
//! 说明: MPU INT 用推挽输出，PA12 无需外部上拉。
//!   注: 本示例只做「中断计数」；实际读姿态数据在其它 app。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const nvic = @import("nvic");
const i2c_soft = @import("i2c_soft");
const mpu6050 = @import("mpu6050");
const oled = @import("oled");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

/// EXTI 中断计数（中断与主循环共享）。
var irq_count: u32 = 0;

/// 注册 EXTI15_10 中断处理程序（PA12 属 line 12 → EXTI15_10）。
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .EXTI15_10 = .{ .c = isrExti15_10 } },
    .overwrite_hal_interrupts = true,
};

fn isrExti15_10() callconv(.c) void {
    nvic.extiClearPending(12);
    irq_count +%= 1;
}

fn showInt(disp: *oled.Oled, x: u8, y: u8, v: u32) void {
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    disp.showString(x, y, s);
}

pub fn main() !void {
    delay.init(8_000_000);
    var disp = oled.initOled();

    // NVIC 优先级分组（对照 MY_NVIC_PriorityGroupConfig(2)）
    nvic.priorityGroupConfig(.g2);

    // ---- EXTI: PA12 下降沿（对照 MiniBalance_EXTI_Init）----
    hal.rcc.enable_clock(.AFIO);
    hal.rcc.enable_clock(.GPIOA);
    const pin = hal.gpio.Pin.from_port(.A, 12);
    pin.set_input_mode(.pull);
    pin.set_pull(.up);
    nvic.extiConfig(.A, 12, .falling);
    // 对照 NVIC 抢占2/子1，g2 分组下 → 优先级 0b1001
    microzig.cpu.interrupt.set_priority(.EXTI15_10, @enumFromInt(0b1001));
    microzig.cpu.interrupt.enable(.EXTI15_10);
    microzig.cpu.interrupt.enable_interrupts();

    // ---- MPU6050: 初始化 + 100Hz data-ready 中断 ----
    const i2c = i2c_soft.initBoardI2c();
    var mpu = mpu6050.init(i2c);
    const ok = mpu.init();
    mpu.setDataReadyRate100hz();
    mpu.enableDataReadyInt(true, true, false); // 推挽, 低有效, 脉冲

    disp.showString(0, 0, "MPU INT + EXTI");
    disp.showString(0, 16, if (ok) "mpu: ok (100Hz)" else "mpu: FAIL");
    disp.showString(0, 40, "irq:");
    disp.refresh();

    var last: u32 = 0;
    while (true) {
        if (irq_count != last) {
            last = irq_count;
            var x: u8 = 40;
            while (x < 120) : (x += 1) {
                var y: u8 = 40;
                while (y < 52) : (y += 1) disp.drawPoint(x, y, 0);
            }
            showInt(&disp, 40, 40, irq_count);
            disp.refresh();
        }
        delay.delayMs(20);
    }
}
