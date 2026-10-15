//! 参考工程:
//!   uart_init(bound) → USART1, 115200-8-N-1
//!     TX = PA9  (复用推挽)
//!     RX = PA10 (浮空输入)
//! 支持的串口: USART1 (PA9/PA10)、USART2 (PA2/PA3)、USART3 (PB10/PB11)。
//! 注意: 引脚映射与参考工程一致，仅 USART1 已在本板验证。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

const Pin = hal.gpio.Pin;
const UartInstance = hal.uart.Instances;
const mdf = microzig.drivers;
const Duration = mdf.time.Duration;

/// 一个串口的句柄。
pub const Usart = struct {
    /// microzig 的 UART 设备
    device: hal.uart.UART,
    tx: Pin,
    rx: Pin,

    /// 对照 uart_init(bound): 配置引脚 + 波特率, 8-N-1。
    /// `clock_speed` 传实际外设时钟（用 rcc.get_clock 取）。
    pub fn apply(self: Usart, clock_speed: u32, baud_rate: u32) void {
        // PA9 TX: 复用推挽输出
        self.tx.set_output_mode(.alternate_function_push_pull, .max_50MHz);
        // PA10 RX: 浮空/上拉输入
        self.rx.set_input_mode(.pull);

        // apply_runtime: 运行时可调用（apply 需 comptime uart 参数）
        self.device.apply_runtime(.{
            .clock_speed = clock_speed,
            .baud_rate = baud_rate,
            .word_bits = .eight,
            .stop_bits = .one,
            .parity = .none,
            .flow_control = .none,
        }) catch {};
    }

    /// 发送一个字节。
    pub fn writeByte(self: Usart, b: u8) void {
        _ = self.device.write_blocking(&[_]u8{b}, null) catch {};
    }

    /// 发送一段数据。
    pub fn write(self: Usart, data: []const u8) void {
        _ = self.device.write_blocking(data, null) catch {};
    }

    /// 发送以 \n 结尾的字符串（附带 \r 以兼容终端）。
    pub fn println(self: Usart, s: []const u8) void {
        self.write(s);
        self.write("\r\n");
    }

    /// 是否有可读数据。
    pub fn readable(self: Usart) bool {
        return self.device.is_readable();
    }

    /// 读一个字节（阻塞，带超时毫秒）。超时返回 null。
    pub fn readByte(self: Usart, timeout_ms: u32) ?u8 {
        var buf: [1]u8 = undefined;
        const n = self.device.read_blocking(&buf, Duration.from_ms(timeout_ms)) catch return null;
        if (n == 0) return null;
        return buf[0];
    }

    /// 读一段数据（阻塞，带超时毫秒）。返回读到的字节数。
    pub fn read(self: Usart, out: []u8, timeout_ms: u32) usize {
        return self.device.read_blocking(out, Duration.from_ms(timeout_ms)) catch 0;
    }
};

/// USART1 的引脚映射（PA9=TX, PA10=RX），与参考工程一致。
pub const Usart1Pins = struct {
    pub const tx: u4 = 9;
    pub const rx: u4 = 10;
};

/// STM32F103 实际使用的 PCLK2（APB2 时钟）。
///
/// 注意: 本项目未调用 `rcc.apply()`，芯片跑在**复位默认的 HSI 8MHz**
/// （未开 PLL）。经实测: BRR=0xd0,mant=13 -> PCLK2 = 38400×16×13 = 8MHz。
/// microzig 的 `rcc.get_clock()` 返回的是「编译期假定时钟」，与实际不符，
/// 故这里显式指定。若将来配了 PLL/其他时钟，需同步修改此值。
pub const default_pclk2: u32 = 8_000_000;

/// 初始化 USART1 (PA9/PA10) 并返回句柄。
///
/// 显式传入 PCLK2, 避免 microzig get_clock 与实际时钟不符的问题。
/// 一般用 `default_pclk2`。
pub fn initUsart1WithClock(baud_rate: u32, pclk2: u32) Usart {
    const usart = Usart{
        .device = hal.uart.UART.init(.USART1),
        .tx = Pin.from_port(.A, Usart1Pins.tx),
        .rx = Pin.from_port(.A, Usart1Pins.rx),
    };

    hal.rcc.enable_clock(.GPIOA);
    hal.rcc.enable_clock(.USART1);

    usart.apply(pclk2, baud_rate);
    return usart;
}

/// 初始化 USART1 (PA9/PA10) 并返回句柄（使用 default_pclk2）。
pub fn initUsart1(baud_rate: u32) Usart {
    return initUsart1WithClock(baud_rate, default_pclk2);
}
