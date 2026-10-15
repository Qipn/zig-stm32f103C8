//! MPU6050 驱动（寄存器层）—— 移植自参考工程。
//!
//! 本模块**只做寄存器层**（不含 DMP）：
//!   * WHO_AM_I 自检
//!   * 读 原始加速度 / 陀螺仪 / 温度
//!   * 初始化（时钟源、量程、退出睡眠）
//!   * 10 点滑动平均滤波（对照 MPU6050_newValues）
//!
//! 参考工程对照:
//!   MPU6050_initialize()        -> Mpu6050.init()
//!   MPU6050_testConnection()    -> Mpu6050.testConnection()
//!   MPU6050_getDeviceID()       -> Mpu6050.deviceId()
//!   MPU6050_getMotion6()        -> Mpu6050.readMotion6()  (读原始 6 轴)
//!   MPU6050_newValues()         -> Mpu6050.pushFiltered() (滑动平均)
//!   Read_Temperature()          -> Mpu6050.readTemperature()
//!
//! 姿态解算（DMP 或互补/卡尔曼滤波）不在本模块，见示例 app。
//!
//! 硬件: 通过软件 I2C 连接（SCL=PB8, SDA=PB9），7 位地址 0x68。

const std = @import("std");
const microzig = @import("microzig");
const i2c_soft = @import("i2c_soft");

const I2c = i2c_soft.I2c;

// ---------- 寄存器地址（对照 mpu6050.h 的 MPU6050_RA_*）----------
pub const RA_SMPLRT_DIV: u8 = 0x19;
pub const RA_CONFIG: u8 = 0x1A;
pub const RA_GYRO_CONFIG: u8 = 0x1B;
pub const RA_ACCEL_CONFIG: u8 = 0x1C;
pub const RA_ACCEL_XOUT_H: u8 = 0x3B;
pub const RA_TEMP_OUT_H: u8 = 0x41;
pub const RA_GYRO_XOUT_H: u8 = 0x43;
pub const RA_USER_CTRL: u8 = 0x6A;
pub const RA_PWR_MGMT_1: u8 = 0x6B;
pub const RA_WHO_AM_I: u8 = 0x75;
pub const RA_INT_PIN_CFG: u8 = 0x37;
pub const RA_INT_ENABLE: u8 = 0x38;

// ---------- 位域常量 ----------
pub const PWR1_SLEEP_BIT: u3 = 6;
pub const PWR1_CLKSEL_BIT: u3 = 2;
pub const PWR1_CLKSEL_LENGTH: u3 = 3;
pub const GCONFIG_FS_SEL_BIT: u3 = 4;
pub const GCONFIG_FS_SEL_LENGTH: u3 = 2;
pub const ACONFIG_AFS_SEL_BIT: u3 = 4;
pub const ACONFIG_AFS_SEL_LENGTH: u3 = 2;
pub const USERCTRL_I2C_MST_EN_BIT: u3 = 5;
pub const INTCFG_I2C_BYPASS_EN_BIT: u3 = 1;
// INT_PIN_CFG(0x37) 位（对照 mpu6050.h 的 MPU6050_INTCFG_*）
pub const INTCFG_INT_LEVEL_BIT: u3 = 7; // 0=高有效, 1=低有效
pub const INTCFG_INT_OPEN_BIT: u3 = 6; // 0=推挽, 1=开漏
pub const INTCFG_LATCH_INT_EN_BIT: u3 = 5; // 1=锁存直到读清, 0=50us 脉冲
pub const INTCFG_INT_RD_CLEAR_BIT: u3 = 4; // 1=任何读清, 0=只读状态寄存器清
// INT_ENABLE(0x38) 位
pub const INTERRUPT_DATA_RDY_BIT: u3 = 0;

// ---------- 取值枚举 ----------
pub const ClockSource = enum(u3) {
    internal = 0x00,
    pll_xgyro = 0x01,
    pll_ygyro = 0x02, // 参考工程用这个
    pll_zgyro = 0x03,
    pll_ext32k = 0x04,
    pll_ext19m = 0x05,
    keep_reset = 0x07,
};

pub const GyroRange = enum(u2) {
    fs_250 = 0x00,
    fs_500 = 0x01,
    fs_1000 = 0x02,
    fs_2000 = 0x03, // 参考工程用这个
};

pub const AccelRange = enum(u2) {
    fs_2 = 0x00, // 参考工程用这个
    fs_4 = 0x01,
    fs_8 = 0x02,
    fs_16 = 0x03,
};

/// 原始 6 轴数据。
pub const Motion6 = struct {
    ax: i16,
    ay: i16,
    az: i16,
    gx: i16,
    gy: i16,
    gz: i16,
};

/// 经滑动平均后的 6 轴数据（对照 MPU6050_FIFO 求平均）。
pub const Filtered6 = struct {
    ax: i16,
    ay: i16,
    az: i16,
    gx: i16,
    gy: i16,
    gz: i16,
};

/// MPU6050 句柄。
pub const Mpu6050 = struct {
    /// 7 位 I2C 地址（0x68 = AD0 接地）。
    addr: u8 = 0x68,
    i2c: I2c,

    /// 10 点滑动平均的 FIFO（对照 MPU6050_FIFO[6][11]，最后一列存均值）。
    fifo: [6][11]i16 = zeroFifo(),

    // ---------- 位操作辅助（对照 IICwriteBits/IICwriteBit）----------

    /// 读-改-写：把寄存器 reg 的 [bit_start-length+1 .. bit_start] 位设为 data。
    fn writeBits(self: Mpu6050, reg: u8, bit_start: u3, length: u3, data: u8) void {
        const b = self.i2c.readReg(self.addr, reg) orelse return;
        const bs: u4 = bit_start;
        const len: u4 = length;
        const mask: u8 = @truncate((@as(u16, 0xFF) << (bs + 1)) |
            (@as(u16, 0xFF) >> (8 - bs + len - 1)));
        var d: u8 = data;
        d <<= @intCast(8 - len);
        d >>= @intCast(7 - bs);
        _ = self.i2c.writeReg(self.addr, reg, (b & mask) | d);
    }

    /// 读-改-写：设置寄存器某一位。
    fn writeBit(self: Mpu6050, reg: u8, bit_num: u3, data: u8) void {
        const b = self.i2c.readReg(self.addr, reg) orelse return;
        const shift: u3 = bit_num;
        const nb = if (data != 0) (b | (@as(u8, 1) << shift)) else (b & ~(@as(u8, 1) << shift));
        _ = self.i2c.writeReg(self.addr, reg, nb);
    }

    // ---------- 公共 API ----------

    /// 对照 MPU6050_setClockSource()。
    pub fn setClockSource(self: Mpu6050, source: ClockSource) void {
        self.writeBits(RA_PWR_MGMT_1, PWR1_CLKSEL_BIT, PWR1_CLKSEL_LENGTH, @intFromEnum(source));
    }

    /// 对照 MPU6050_setFullScaleGyroRange()。
    pub fn setFullScaleGyroRange(self: Mpu6050, range: GyroRange) void {
        self.writeBits(RA_GYRO_CONFIG, GCONFIG_FS_SEL_BIT, GCONFIG_FS_SEL_LENGTH, @intFromEnum(range));
    }

    /// 对照 MPU6050_setFullScaleAccelRange()。
    pub fn setFullScaleAccelRange(self: Mpu6050, range: AccelRange) void {
        self.writeBits(RA_ACCEL_CONFIG, ACONFIG_AFS_SEL_BIT, ACONFIG_AFS_SEL_LENGTH, @intFromEnum(range));
    }

    /// 对照 MPU6050_setSleepEnabled()。
    pub fn setSleepEnabled(self: Mpu6050, enabled: u1) void {
        self.writeBit(RA_PWR_MGMT_1, PWR1_SLEEP_BIT, enabled);
    }

    /// 对照 MPU6050_setI2CMasterModeEnabled()。
    pub fn setI2CMasterModeEnabled(self: Mpu6050, enabled: u1) void {
        self.writeBit(RA_USER_CTRL, USERCTRL_I2C_MST_EN_BIT, enabled);
    }

    /// 对照 MPU6050_setI2CBypassEnabled()。
    pub fn setI2CBypassEnabled(self: Mpu6050, enabled: u1) void {
        self.writeBit(0x37, INTCFG_I2C_BYPASS_EN_BIT, enabled);
    }

    /// 对照 MPU6050_getDeviceID(): 读 WHO_AM_I（正常应为 0x68）。失败返回 null。
    pub fn deviceId(self: Mpu6050) ?u8 {
        return self.i2c.readReg(self.addr, RA_WHO_AM_I);
    }

    /// 对照 MPU6050_testConnection(): 连接正常返回 true。
    pub fn testConnection(self: Mpu6050) bool {
        return (self.deviceId() orelse return false) == 0x68;
    }

    /// 对照 MPU6050_initialize(): 时钟源 + 量程 + 退出睡眠 + 关辅机/旁路。
    /// 返回是否连接成功。
    pub fn init(self: Mpu6050) bool {
        if (!self.testConnection()) return false;
        self.setClockSource(.pll_ygyro); // 参照考工程
        self.setFullScaleGyroRange(.fs_2000);
        self.setFullScaleAccelRange(.fs_2);
        self.setSleepEnabled(0);
        self.setI2CMasterModeEnabled(0);
        self.setI2CBypassEnabled(0);
        return true;
    }

    /// 设置 DLPF 配置（CONFIG 寄存器 0x1A 的 [2:0] 位）。
    /// 值与截止频率对应见 mpu6050.h 的 MPU6050_DLPF_BW_*：
    ///   0=256Hz, 1=188Hz, 2=98Hz, 3=42Hz, 4=20Hz, 5=10Hz, 6=5Hz, 7=保留。
    /// 注：DLPF 使能（非 0）时陀螺仪输出率为 1kHz；关闭时 8kHz。
    pub fn setDLPF(self: Mpu6050, cfg: u3) void {
        self.writeBits(RA_CONFIG, 0, 3, cfg);
    }

    /// 设置采样率分频（SMPLRT_DIV 0x19）。
    /// 采样率 = 陀螺输出率 / (1 + div)。陀螺输出率：DLPF 开=1kHz，关=8kHz。
    pub fn setSampleRateDiv(self: Mpu6050, div: u8) void {
        _ = self.i2c.writeReg(self.addr, RA_SMPLRT_DIV, div);
    }

    /// 配置 data-ready 中断频率为 100Hz（即每 10ms 一次）。
    /// 做法: DLPF=1（188Hz，陀螺输出率 1kHz）+ SMPLRT_DIV=9 → 1000/(1+9)=100Hz。
    pub fn setDataReadyRate100hz(self: Mpu6050) void {
        self.setDLPF(1);
        self.setSampleRateDiv(9);
    }

    /// 通用：设目标采样率 Hz（假设 DLPF 已开启，陀螺输出 1kHz）。
    /// 例: target=100 → div=9; target=200 → div=4; target=50 → div=19。
    pub fn setDataReadyRateHz(self: Mpu6050, target_hz: u16) void {
        if (target_hz == 0) return;
        const div: u32 = if (target_hz >= 1000) 0 else (1000 / target_hz - 1);
        self.setSampleRateDiv(@intCast(@min(div, 255)));
    }

    /// 使能 INT 引脚的 **data-ready 中断**：每采样一个新数据，INT 输出一个脉冲。
    ///
    /// 硬件前提: INT 脚（本板 PA12）需有上拉才能由低变高。若板上 INT 悬空、
    /// 无外部上拉，可在 STM32 侧用内部上拉（见 exti-demo）。
    ///
    /// 参数 `push_pull`: true=推挽输出（不依赖外部上拉，推荐）；false=开漏。
    /// 参数 `active_low`: true=低有效（下降沿），false=高有效。
    /// 参数 `latch`: true=锁存至读清；false=50us 脉冲（下降沿友好）。
    pub fn enableDataReadyInt(self: Mpu6050, push_pull: bool, active_low: bool, latch: bool) void {
        // INT_PIN_CFG(0x37): 配置 INT 引脚电气与有效电平
        //   INT_LEVEL(bit7): 0=高有效, 1=低有效
        //   INT_OPEN (bit6): 0=推挽,   1=开漏
        //   LATCH_INT_EN(bit5): 1=锁存, 0=脉冲
        //   INT_RD_CLEAR(bit4): 1=任何读清
        self.writeBit(RA_INT_PIN_CFG, INTCFG_INT_LEVEL_BIT, if (active_low) 1 else 0);
        self.writeBit(RA_INT_PIN_CFG, INTCFG_INT_OPEN_BIT, if (push_pull) 0 else 1);
        self.writeBit(RA_INT_PIN_CFG, INTCFG_LATCH_INT_EN_BIT, if (latch) 1 else 0);
        self.writeBit(RA_INT_PIN_CFG, INTCFG_INT_RD_CLEAR_BIT, 1);

        // INT_ENABLE(0x38): 使能 data-ready 中断
        self.writeBit(RA_INT_ENABLE, INTERRUPT_DATA_RDY_BIT, 1);
    }

    /// 关闭所有 INT 中断源。
    pub fn disableInt(self: Mpu6050) void {
        _ = self.i2c.writeReg(self.addr, RA_INT_ENABLE, 0x00);
    }

    /// 对照 MPU6050_getMotion6(): 读原始加速度+陀螺仪（14 字节连读）。
    /// 失败返回 null。
    pub fn readMotion6(self: Mpu6050) ?Motion6 {
        var buf: [14]u8 = undefined;
        if (!self.i2c.readRegs(self.addr, RA_ACCEL_XOUT_H, &buf)) return null;
        return .{
            .ax = be16(buf[0], buf[1]),
            .ay = be16(buf[2], buf[3]),
            .az = be16(buf[4], buf[5]),
            // buf[6..8] = 温度
            .gx = be16(buf[8], buf[9]),
            .gy = be16(buf[10], buf[11]),
            .gz = be16(buf[12], buf[13]),
        };
    }

    /// 对照 MPU6050_newValues(): 把新数据推入 10 点滑动平均，返回平均值。
    pub fn pushFiltered(self: *Mpu6050, m: Motion6) Filtered6 {
        const raw = [6]i16{ m.ax, m.ay, m.az, m.gx, m.gy, m.gz };
        var avg: [6]i16 = undefined;
        for (0..6) |ch| {
            // 移位
            var i: usize = 1;
            while (i < 10) : (i += 1) self.fifo[ch][i - 1] = self.fifo[ch][i];
            self.fifo[ch][9] = raw[ch]; // 新值放最后
            var sum: i32 = 0;
            for (0..10) |k| sum += self.fifo[ch][k];
            const a: i16 = @intCast(@divTrunc(sum, 10));
            self.fifo[ch][10] = a;
            avg[ch] = a;
        }
        return .{ .ax = avg[0], .ay = avg[1], .az = avg[2], .gx = avg[3], .gy = avg[4], .gz = avg[5] };
    }

    /// 对照 Read_Temperature(): 读温度（返回摄氏 × 10 的整数）。失败返回 null。
    pub fn readTemperature10x(self: Mpu6050) ?i32 {
        var buf: [2]u8 = undefined;
        if (!self.i2c.readRegs(self.addr, RA_TEMP_OUT_H, &buf)) return null;
        var temp: i32 = @as(i16, be16(buf[0], buf[1]));
        if (temp > 32768) temp -= 65536;
        return @intFromFloat((36.53 + @as(f32, @floatFromInt(temp)) / 340.0) * 10.0);
    }
};

/// 大端拼 16 位（MPU6050 寄存器高字节在前）。
inline fn be16(hi: u8, lo: u8) i16 {
    return @bitCast((@as(u16, hi) << 8) | lo);
}

/// 全零的滑动平均缓冲。
fn zeroFifo() [6][11]i16 {
    return @splat(@as([11]i16, @splat(0)));
}

/// 便捷入口：用给定 I2C 总线创建句柄（addr 默认 0x68）。
pub fn init(i2c: I2c) Mpu6050 {
    return .{ .i2c = i2c };
}
