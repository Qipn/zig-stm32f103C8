//! DMP 示例 —— 移植参考工程的 DMP 层。
//!
//! 用 DMP 库（`modules/dmp/` 的 C 源码，直接编入固件）
//! 输出四元数 → 欧拉角，显示到 OLED。
//!
//! 对照:
//!   DMP_Init()  -> dmp.init()
//!   Read_DMP()  -> dmp.readEuler()  (内部 readQuat + 四元数→欧拉角)
//!
//! 现象（OLED）:
//!   * `dmp: ok` / `FAIL`
//!   * `R:` Roll，`P:` Pitch，`Y:` Yaw（单位 0.1 度）
//!   * 转动板子，角度随之变化
//!
//! 注: DMP 固件初始化较慢（自检 + 加载固件），开机约需数百 ms。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const i2c_soft = @import("i2c_soft");
const dmp_mod = @import("dmp");
const oled = @import("oled");
const delay = @import("delay");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

fn showInt(disp: *oled.Oled, x: u8, y: u8, v: i32) void {
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    disp.showString(x, y, s);
}

pub fn main() !void {
    delay.init(8_000_000);
    var disp = oled.initOled();

    const i2c = i2c_soft.initBoardI2c();
    var dmp = dmp_mod.init(i2c);

    disp.showString(0, 0, "DMP init...");
    disp.refresh();

    const ok = dmp.init();

    disp.showString(0, 16, if (ok) "dmp: ok" else "dmp: FAIL");
    disp.showString(0, 32, "R:");
    disp.showString(0, 48, "P:");
    disp.refresh();

    while (true) {
        if (dmp.readEuler()) |e| {
            // 清值区
            var x: u8 = 12;
            while (x < 120) : (x += 1) {
                var y: u8 = 32;
                while (y < 60) : (y += 1) disp.drawPoint(x, y, 0);
            }
            // 显示为 0.1 度
            showInt(&disp, 12, 32, @intFromFloat(e.roll * 10.0));
            showInt(&disp, 12, 48, @intFromFloat(e.pitch * 10.0));
            disp.refresh();
        }
        delay.delayMs(50);
    }
}
