//! PA12 引脚电平读取诊断 —— 不涉及 EXTI，只验证「能否正确读 GPIO 输入」。
//!
//! 用途: 把「EXTI 不计数」的问题切分为：
//!   * 若读到的电平正确（碰 GND→0、碰 3V3→1）→ GPIO 读取正常，
//!     问题在外部（MPU6050 INT 把 PA12 钳低）。
//!   * 若读到的电平乱/恒定不对 → 引脚配置或硬件问题。
//!
//! 现象（OLED）:
//!   * `pull-up  :` 显示「使能内部上拉」时读到的 PA12 电平
//!   * `pull-none:` 显示「浮空（无上拉）」时读到的 PA12 电平
//!   * `level     :` 当前实时电平（每 100ms 刷新）
//!   * 用杜邦线把 PA12 接 GND / 3V3，观察是否相应变 0 / 1
//!
//! 对照参考工程: PA12 = 上拉输入（GPIO_Mode_IPU），接 MPU6050 INT。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const oled = @import("oled");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    delay.init(8_000_000);
    var disp = oled.initOled();

    hal.rcc.enable_clock(.GPIOA);
    const pin = hal.gpio.Pin.from_port(.A, 12);

    // 第一次：上拉输入
    pin.set_input_mode(.pull);
    pin.set_pull(.up);
    delay.delayMs(10);
    const lvl_pullup = pin.read();

    // 第二次：浮空输入
    pin.set_input_mode(.floating);
    delay.delayMs(10);
    const lvl_float = pin.read();

    // 之后恢复为上拉（对照参考工程），用于实时观察
    pin.set_input_mode(.pull);
    pin.set_pull(.up);

    disp.showString(0, 0, "PA12 read test");
    disp.showString(0, 16, "pullup:");
    disp.showString(0, 32, "float :");
    disp.showString(0, 48, "live  :");
    disp.refresh();

    // 静态结果（拉/浮空各显示 0/1）
    showBit(&disp, 60, 16, lvl_pullup);
    showBit(&disp, 60, 32, lvl_float);
    disp.refresh();

    while (true) {
        const live = pin.read();
        showBit(&disp, 60, 48, live);
        disp.refresh();
        delay.delayMs(100);
    }
}

fn showBit(disp: *oled.Oled, x: u8, y: u8, v: u1) void {
    disp.showString(x, y, if (v == 1) "1 (high)" else "0 (low) ");
}
