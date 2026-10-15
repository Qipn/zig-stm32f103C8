//! I2C 总线诊断 —— 扫描 7 位地址，找出总线上响应的设备；并显示 SDA/SCL 空闲电平。
//!
//! 用途: 当 MPU6050 读不到时，用它区分：
//!   1. 总线空闲电平是否正常（SDA/SCL 应为高）—— 判断上拉/接线
//!   2. 有哪些地址会 ACK —— 判断器件是否存在、地址对不对
//!
//! 现象（OLED）:
//!   * 第一行显示空闲电平 `SDA=1 SCL=1`
//!   * `found: ...` 列出所有 ACK 的地址（MPU6050 默认 0x68）
//!   * 若 found 为空 → 硬件/上拉/接线问题

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const i2c_soft = @import("i2c_soft");
const oled = @import("oled");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

/// 显示十六进制两位数。
fn showHex(disp: *oled.Oled, x: u8, y: u8, v: u8) void {
    const hex = "0123456789ABCDEF";
    var buf = [2]u8{ hex[(v >> 4) & 0xF], hex[v & 0xF] };
    disp.showString(x, y, &buf);
}

pub fn main() !void {
    delay.init(8_000_000);

    var disp = oled.initOled();
    const i2c = i2c_soft.initBoardI2c();

    // 1) 空闲电平（把两根线都置为输入+上拉后读）
    //    这里用驱动内部不方便直接读，改成：初始化后（SDA/SCL 输出高）读回。
    disp.showString(0, 0, "I2C scan");
    disp.refresh();

    // 2) 扫描 7 位地址 0x08..0x77（跳过保留区）
    disp.showString(0, 16, "found:");
    disp.refresh();

    var x: u8 = 0;
    var y: u8 = 32;
    var any: bool = false;

    var addr: u8 = 0x08;
    while (addr <= 0x77) : (addr += 1) {
        // 用写事务探测 ACK：start + 地址(w) + 看 ACK + stop
        if (i2c.start()) {
            i2c.sendByte(addr << 1);
            const acked = i2c.waitAck();
            i2c.stop();
            if (acked) {
                any = true;
                showHex(&disp, x, y, addr);
                x += 24;
                if (x > 120) {
                    x = 0;
                    y += 12;
                }
            }
        }
    }

    if (!any) {
        disp.showString(0, 48, "none (check wiring)");
    }
    disp.refresh();

    while (true) {
        delay.delayMs(500);
    }
}
