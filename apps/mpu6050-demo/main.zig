//! MPU6050 示例 —— 移植参考工程 `MiniBalance_HARDWARE/MPU6050` + `IIC`。
//!
//! 通过**软件 I2C**（SCL=PB8, SDA=PB9）读 MPU6050 原始数据，显示到 OLED。
//!
//! 本示例只做**寄存器层**（无 DMP、无姿态解算）：
//!   * 开机自检 WHO_AM_I（应显示 0x68）
//!   * 周期读 加速度 / 陀螺仪 / 温度
//!   * 加速度做 10 点滑动平均（对照 MPU6050_newValues）
//!
//! 现象（OLED）:
//!   * 第一行显示 MPU6050 的 WHO_AM_I（成功为 68）
//!   * 之后显示 ax/ay/az/gx/gy/gz/temp 的实时值
//!   * 晃动板子数值应明显变化
//!
//! 注: 用 SysTick 延时（delay），不用 hal.time（避免依赖时钟子系统）。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const i2c_soft = @import("i2c_soft");
const mpu6050 = @import("mpu6050");
const oled = @import("oled");
const led = @import("led");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

/// 有符号数转字符串（右对齐到 len 位，含符号）。
fn showInt(disp: *oled.Oled, x: u8, y: u8, v: i32, len: u8) void {
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    _ = len;
    disp.showString(x, y, s);
}

pub fn main() !void {
    delay.init(8_000_000);

    const my_led = led.initBoardLed();
    var disp = oled.initOled();

    // 软件 I2C + MPU6050
    const i2c = i2c_soft.initBoardI2c();
    var mpu = mpu6050.init(i2c);

    disp.showString(0, 0, "MPU6050 (soft I2C)");
    disp.showString(0, 16, "WHO_AM_I:");
    disp.refresh();

    const ok = mpu.init();
    const id = mpu.deviceId();

    // 显示 WHO_AM_I（0x68 = 0x36 + 0x32 两个字符的十六进制？这里直接显示十进制）
    if (id) |v| {
        disp.showString(72, 16, if (v == 0x68) "0x68 OK" else "0x?? ERR");
    } else {
        disp.showString(72, 16, "READ ERR");
    }
    disp.refresh();

    if (!ok) {
        // 自检失败：LED 快闪提示，不再继续
        while (true) {
            my_led.toggle();
            delay.delayMs(100);
        }
    }

    disp.showString(0, 32, "ax:");
    disp.showString(64, 32, "ay:");
    disp.showString(0, 48, "az:");
    disp.showString(64, 48, "T:");
    disp.refresh();

    while (true) {
        my_led.toggle(); // 心跳

        if (mpu.readMotion6()) |m| {
            const f = mpu.pushFiltered(m);
            // OLED 只有 128x64，显示 ay 与温度做代表，其余滚动打印更好；
            // 这里显示 ax/ay/az 与温度（缩小到合适位数）。
            showInt(&disp, 20, 32, f.ax, 5);
            showInt(&disp, 84, 32, f.ay, 5);
            showInt(&disp, 20, 48, f.az, 5);
            if (mpu.readTemperature10x()) |t| {
                showInt(&disp, 78, 48, t, 5); // 摄氏 × 10
            }
            disp.refresh();
        }

        delay.delayMs(100);
    }
}
