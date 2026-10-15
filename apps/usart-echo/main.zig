//! USART1 发送测试（PA9=TX, 115200-8-N-1）。
//!
//! 硬件: 板载 CH340 已连到 PA9/PA10，用板子 USB 口即可。
//! 上电后每 ~0.5s 发送一行 "CHK n"。
//!
//! 关键: PCLK2 由 usart.default_pclk2 显式给出（芯片跑复位默认 HSI 8MHz）。
//! 若用 microzig 的 rcc.get_clock()，返回的是编译期假定时钟，与实测不符，
//! 会导致 BRR 算错、波特率不匹配（收不到数据）。
//!
//! 接收（readable/readByte）暂未验证通过，见 TODO。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const usart = @import("usart");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    const u = usart.initUsart1(115200);

    u.write("USART1 ready\r\n");

    var n: u32 = 0;
    while (true) {
        u.write("CHK ");
        u.writeByte(@intCast('0' + (n % 10)));
        u.write("\r\n");
        n +%= 1;

        // 忙等 ~0.5s（不依赖 timer/时钟）
        var i: u32 = 0;
        while (i < 400_000) : (i += 1) asm volatile ("nop");
    }
}
