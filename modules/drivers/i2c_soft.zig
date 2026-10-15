//! 硬件: **SCL = PB8, SDA = PB9**（两线 + 外部上拉）。
//!
//! 设计:
//!   * 两线均推挽输出（B570 无外部上拉也能工作）。
//!   * SDA 双向：发送时输出，接收时切输入。
//!   * 地址参数为 7 位，内部 `<<1` 补 R/W 位。
//!
//! 注意: 时序行为已在硬件（MPU6050 + DMP）验证，勿改动延时值与电平顺序。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const delay = @import("delay");

const Pin = hal.gpio.Pin;
const RCC = microzig.chip.peripherals.RCC;

/// 等待 ACK 的最大轮询次数。
const ack_timeout: u8 = 50;

/// 软件 I2C 总线句柄。
pub const I2c = struct {
    scl: Pin,
    sda: Pin,

    inline fn sclHigh(self: I2c) void {
        self.scl.put(1);
    }
    inline fn sclLow(self: I2c) void {
        self.scl.put(0);
    }
    inline fn sdaHigh(self: I2c) void {
        self.sda.put(1);
    }
    inline fn sdaLow(self: I2c) void {
        self.sda.put(0);
    }
    /// SDA 设为推挽输出。
    inline fn sdaOut(self: I2c) void {
        self.sda.set_output_mode(.general_purpose_push_pull, .max_50MHz);
    }
    /// SDA 设为上拉输入。
    inline fn sdaIn(self: I2c) void {
        self.sda.set_input_mode(.pull);
        self.sda.set_pull(.up);
    }
    inline fn readSda(self: I2c) u1 {
        return self.sda.read();
    }
    inline fn readScl(self: I2c) u1 {
        return self.scl.read();
    }
    /// 位延时，集中一处便于调时序。
    inline fn busDelay(self: I2c) void {
        _ = self;
        delay.delayUs(1);
    }

    /// 使能 GPIO 时钟，两线配推挽输出，初值高。
    pub fn init(self: I2c) I2c {
        inline for (.{ self.scl, self.sda }) |pin| {
            const port_index: u5 = @intCast(@backingInt(pin) / 16);
            const bit: u32 = @as(u32, 1) << (port_index + 2);
            RCC.APB2ENR.raw |= bit;
            _ = RCC.APB2ENR.raw & bit;
        }
        // 两根线都要设为输出：漏配 SCL 会停在复位默认输入态，总线不响应。
        self.sdaOut();
        self.scl.set_output_mode(.general_purpose_push_pull, .max_50MHz);
        self.sclHigh();
        self.sdaHigh();
        return self;
    }

    /// 起始信号。成功返回 true。
    pub fn start(self: I2c) bool {
        self.sdaOut();
        self.sdaHigh();
        if (self.readSda() == 0) return false; // 总线被占用
        self.sclHigh();
        self.busDelay();
        self.sdaLow(); // SCL 高时 SDA 下跳 = START
        if (self.readSda() != 0) return false;
        self.busDelay();
        self.sclLow();
        return true;
    }

    /// 停止信号。
    pub fn stop(self: I2c) void {
        self.sdaOut();
        self.sclLow();
        self.sdaLow();
        self.busDelay();
        self.sclHigh();
        self.sdaHigh(); // SCL 高时 SDA 上跳 = STOP
        self.busDelay();
    }

    /// 等待应答。收到 ACK 返回 true。
    pub fn waitAck(self: I2c) bool {
        var err: u8 = 0;
        self.sdaIn();
        self.sdaHigh();
        self.busDelay();
        self.sclHigh();
        self.busDelay();
        while (self.readSda() != 0) {
            err += 1;
            if (err > ack_timeout) {
                self.stop();
                return false;
            }
            self.busDelay();
        }
        self.sclLow();
        return true;
    }

    fn ack(self: I2c) void {
        self.sclLow();
        self.sdaOut();
        self.sdaLow();
        self.busDelay();
        self.sclHigh();
        self.busDelay();
        self.sclLow();
    }

    fn nack(self: I2c) void {
        self.sclLow();
        self.sdaOut();
        self.sdaHigh();
        self.busDelay();
        self.sclHigh();
        self.busDelay();
        self.sclLow();
    }

    /// 发送一个字节（MSB 先出）。
    pub fn sendByte(self: I2c, txd_in: u8) void {
        var txd = txd_in;
        self.sdaOut();
        self.sclLow();
        var t: u4 = 0;
        while (t < 8) : (t += 1) {
            if ((txd & 0x80) != 0) self.sdaHigh() else self.sdaLow();
            txd <<= 1;
            self.busDelay();
            self.sclHigh();
            self.busDelay();
            self.sclLow();
            if (t == 7) self.sdaHigh(); // 末位后释放总线
        }
    }

    /// 读一个字节。`send_ack` 为 false 时发 NACK（最后一字节）。
    pub fn readByte(self: I2c, send_ack: bool) u8 {
        var receive: u8 = 0;
        self.sdaIn();
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            self.sclLow();
            delay.delayUs(2);
            self.sclHigh();
            receive <<= 1;
            if (self.readSda() != 0) receive += 1;
            delay.delayUs(2);
        }
        if (send_ack) self.ack() else self.nack();
        return receive;
    }

    /// 发送一个字节并等待 ACK。
    pub fn sendByteAck(self: I2c, b: u8) bool {
        self.sendByte(b);
        return self.waitAck();
    }

    /// 向 7 位地址设备的寄存器写 len 字节。
    pub fn writeRegs(self: I2c, addr: u8, reg: u8, data: []const u8) bool {
        if (!self.start()) return false;
        if (!self.sendByteAck(addr << 1)) {
            self.stop();
            return false;
        }
        self.sendByte(reg);
        _ = self.waitAck();
        for (data) |b| {
            if (!self.sendByteAck(b)) {
                self.stop();
                return false;
            }
        }
        self.stop();
        return true;
    }

    /// 从 7 位地址设备的寄存器连读 len 字节。
    pub fn readRegs(self: I2c, addr: u8, reg: u8, buf: []u8) bool {
        if (!self.start()) return false;
        if (!self.sendByteAck(addr << 1)) {
            self.stop();
            return false;
        }
        self.sendByte(reg);
        _ = self.waitAck();
        _ = self.start(); // 重复起始
        if (!self.sendByteAck((addr << 1) + 1)) {
            self.stop();
            return false;
        }
        var remaining = buf.len;
        for (buf) |*b| {
            remaining -= 1;
            b.* = self.readByte(remaining != 0); // 最后一字节 NACK
        }
        self.stop();
        return true;
    }

    /// 写单个寄存器。
    pub fn writeReg(self: I2c, addr: u8, reg: u8, value: u8) bool {
        return self.writeRegs(addr, reg, &[_]u8{value});
    }

    /// 读单个寄存器。失败返回 null。
    pub fn readReg(self: I2c, addr: u8, reg: u8) ?u8 {
        var b: [1]u8 = undefined;
        if (!self.readRegs(addr, reg, &b)) return null;
        return b[0];
    }

    /// 检测 7 位地址设备是否存在（总线空闲 + 应答 ACK）。
    pub fn checkDevice(self: I2c, addr: u8) bool {
        if (self.readSda() == 0 or self.readScl() == 0) return false;
        if (!self.start()) return false;
        const acked = self.sendByteAck(addr << 1);
        self.stop();
        return acked;
    }

    /// 扫描总线，返回第一个会 ACK 的 7 位地址（无则 null）。
    pub fn scan(self: I2c) ?u8 {
        var addr: u8 = 0x08;
        while (addr <= 0x77) : (addr += 1) {
            if (self.checkDevice(addr)) return addr;
        }
        return null;
    }
};

/// 板级软件 I2C：SCL=PB8, SDA=PB9。
pub const board_i2c = I2c{
    .scl = Pin.from_port(.B, 8),
    .sda = Pin.from_port(.B, 9),
};

/// 初始化板载软件 I2C 并返回句柄。
pub fn initBoardI2c() I2c {
    return board_i2c.init();
}
