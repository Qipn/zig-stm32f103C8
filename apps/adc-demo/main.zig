//! ADC 示例 —— 移植参考工程 `MiniBalance_HARDWARE/ADC` (adc.c)。
//!
//! 通过 **PA6 (ADC1_IN6)** 读电池分压，计算电压并显示到 OLED。
//!
//! 现象（OLED）:
//!   * `adc:`  显示 12 位原始值（0..4095）
//!   * `batt:` 显示电池电压（单位 0.01V，如 `1240` = 12.40V）
//!   * `mv:`   显示毫伏原始值
//!
//! 对照:
//!   Adc_Init()          -> adc.initBoardAdc()
//!   Get_Adc(6)          -> a.readBatteryRaw()
//!   Get_battery_volt()  -> a.batteryVoltMv()

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const adc = @import("adc");
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
    var a = adc.initBoardAdc();

    disp.showString(0, 0, "ADC battery (PA6)");
    disp.showString(0, 16, "adc:");
    disp.showString(0, 32, "mv:");
    disp.showString(0, 48, "0.01V:");
    disp.refresh();

    while (true) {
        const raw = a.readBatteryRaw();
        const mv = a.batteryVoltMv();

        // 清值区再重画
        var x: u8 = 30;
        while (x < 120) : (x += 1) {
            var y: u8 = 16;
            while (y < 60) : (y += 1) disp.drawPoint(x, y, 0);
        }

        showInt(&disp, 30, 16, raw);
        showInt(&disp, 30, 32, mv);
        showInt(&disp, 42, 48, @divTrunc(mv, 10)); // 0.01V
        disp.refresh();

        delay.delayMs(200);
    }
}
