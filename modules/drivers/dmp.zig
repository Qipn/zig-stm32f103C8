//! DMP 驱动 —— 移植自参考工程的 DMP 层。
//!
//! 本模块**不翻译** DMP 的 5200 行 C，而是**直接编译其原始 C 源码**
//! （`inv_mpu.c` + `inv_mpu_dmp_motion_driver.c`，见 `modules/dmp/`），
//! 由 `build.zig` 的 `fw.add_c_source_file` 编入固件。
//! 说明:
//!   * DMP 库用 **7 位地址**（0x68），与 i2c_soft 一致。
//!   * `i2c_write`/`i2c_read` 返回 0=成功, 非0=失败（与库期望一致）。
//!   * DMP 固件镜像约 3KB，占 flash。

const std = @import("std");
const microzig = @import("microzig");
const i2c_soft = @import("i2c_soft");
const delay = @import("delay");

/// 运行期使用的软件 I2C 总线（DMP 库通过 C 上钩调用，故需全局）。
var g_i2c: ?i2c_soft.I2c = null;

/// MPU6050 的 7 位地址。
const DMP_ADDR: u8 = 0x68;

// ============================================================
// 1) 导出给 DMP C 库的平台函数（C ABI）
// ============================================================

/// 向 7 位地址设备的寄存器写 length 字节。返回 0 成功。
export fn i2c_write(slave_addr: u8, reg_addr: u8, length: u8, data: [*]const u8) callconv(.c) c_int {
    if (g_i2c == null) return 1;
    const ok = g_i2c.?.writeRegs(slave_addr, reg_addr, data[0..length]);
    return if (ok) 0 else 1;
}

/// 从 7 位地址设备的寄存器读 length 字节。返回 0 成功。
export fn i2c_read(slave_addr: u8, reg_addr: u8, length: u8, data: [*]u8) callconv(.c) c_int {
    if (g_i2c == null) return 1;
    const ok = g_i2c.?.readRegs(slave_addr, reg_addr, data[0..length]);
    return if (ok) 0 else 1;
}

/// 毫秒延时（对照参考工程 delay_ms）。
export fn delay_ms(num_ms: c_ulong) callconv(.c) void {
    delay.delayMs(@intCast(num_ms));
}

/// 取当前时间（DMP 库用它打时间戳；我们无 RTC，返回 0）。
export fn get_ms(count: *c_ulong) callconv(.c) void {
    count.* = 0;
}

/// long 绝对值（DMP 库自检用）。compiler-rt 在 freestanding 下不一定提供，故自带。
export fn labs(x: c_long) callconv(.c) c_long {
    return if (x < 0) -x else x;
}

/// 内存比较（DMP 库加载固件时用）。
export fn memcmp(s1: [*]const u8, s2: [*]const u8, n: c_ulong) callconv(.c) c_int {
    var i: c_ulong = 0;
    while (i < n) : (i += 1) {
        const a = s1[i];
        const b = s2[i];
        if (a != b) return @as(c_int, a) - @as(c_int, b);
    }
    return 0;
}

// ============================================================
// 2) 声明 DMP C 库导出的函数（extern）
// ============================================================

extern fn mpu_init() c_int;
extern fn mpu_set_sensors(sensors: u8) c_int;
extern fn mpu_configure_fifo(sensors: u8) c_int;
extern fn mpu_set_sample_rate(rate: u16) c_int;
extern fn mpu_set_dmp_state(enable: u8) c_int;
extern fn mpu_get_gyro_sens(sens: *f32) c_int;
extern fn mpu_get_accel_sens(sens: *u16) c_int;
extern fn mpu_run_self_test(gyro: [*]c_long, accel: [*]c_long) c_int;
extern fn mpu_get_lpf(lpf: *u16) c_int;
extern fn mpu_set_lpf(lpf: u16) c_int;

extern fn dmp_load_motion_driver_firmware() c_int;
extern fn dmp_set_orientation(orient: u16) c_int;
extern fn dmp_enable_feature(mask: u16) c_int;
extern fn dmp_set_fifo_rate(rate: u16) c_int;
extern fn dmp_read_fifo(gyro: [*]i16, accel: [*]i16, quat: [*]c_long, timestamp: *c_ulong, sensors: *i16, more: *u8) c_int;
extern fn dmp_set_gyro_bias(bias: [*]c_long) c_int;
extern fn dmp_set_accel_bias(bias: [*]c_long) c_int;

// DMP 特性掩码（对照 inv_mpu_dmp_motion_driver.h）
pub const FEATURE_6X_LP_QUAT: u16 = 0x0010;
pub const FEATURE_TAP: u16 = 0x0001;
pub const FEATURE_ANDROID_ORIENT: u16 = 0x0002;
pub const FEATURE_SEND_RAW_ACCEL: u16 = 0x0040;
pub const FEATURE_SEND_CAL_GYRO: u16 = 0x0100;
pub const FEATURE_GYRO_CAL: u16 = 0x0020;

/// sensors 位（对照 inv_mpu.h）
pub const INV_XYZ_GYRO: u8 = 0x70;
pub const INV_XYZ_ACCEL: u8 = 0x08;

pub const WXYZ_QUAT: i16 = 0x100;

/// q30 定标（DMP 四元数为 Q30 定点）。
const Q30: f32 = 1073741824.0;

/// 欧拉角（度）。
pub const Euler = struct {
    roll: f32,
    pitch: f32,
    yaw: f32,
};

/// 四元数（已归一化到 -1..1）。
pub const Quat = struct {
    w: f32,
    x: f32,
    y: f32,
    z: f32,
};

// ============================================================
// 3) Zig 风格封装
// ============================================================

/// DMP 句柄。
pub const Dmp = struct {
    i2c: i2c_soft.I2c,
    /// 陀螺仪朝向矩阵的标量（对照参考工程 gyro_orientation）
    orientation: u16 = 0x0064,
    initialized: bool = false,

    /// 对照 DMP_Init(): 初始化 MPU + 加载 DMP 固件 + 配置特性 + 使能 DMP。
    /// 返回是否成功。
    pub fn init(self: *Dmp) bool {
        g_i2c = self.i2c;

        if (mpu_init() != 0) return false;
        if (mpu_set_sensors(INV_XYZ_GYRO | INV_XYZ_ACCEL) != 0) return false;
        if (mpu_configure_fifo(INV_XYZ_GYRO | INV_XYZ_ACCEL) != 0) return false;
        if (mpu_set_sample_rate(200) != 0) return false;
        if (dmp_load_motion_driver_firmware() != 0) return false;
        if (dmp_set_orientation(self.orientation) != 0) return false;
        const feat: u16 = FEATURE_6X_LP_QUAT | FEATURE_TAP |
            FEATURE_ANDROID_ORIENT | FEATURE_SEND_RAW_ACCEL |
            FEATURE_SEND_CAL_GYRO | FEATURE_GYRO_CAL;
        if (dmp_enable_feature(feat) != 0) return false;
        if (dmp_set_fifo_rate(200) != 0) return false;

        // 自检 + 偏置（失败不致命）
        self.runSelfTest();

        if (mpu_set_dmp_state(1) != 0) return false;
        self.initialized = true;
        return true;
    }

    /// 对照参考工程 run_self_test(): 自检通过则下发陀螺/加速度偏置到 DMP。
    fn runSelfTest(self: *Dmp) void {
        _ = self;
        var gyro_bias: [3]c_long = .{ 0, 0, 0 };
        var accel_bias: [3]c_long = .{ 0, 0, 0 };
        if (mpu_run_self_test(&gyro_bias, &accel_bias) != 0x7) return;

        var gyro_sens: f32 = 0;
        _ = mpu_get_gyro_sens(&gyro_sens);
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            gyro_bias[i] = @intFromFloat(@as(f32, @floatFromInt(gyro_bias[i])) * gyro_sens);
        }
        _ = dmp_set_gyro_bias(&gyro_bias);

        var accel_sens: u16 = 0;
        _ = mpu_get_accel_sens(&accel_sens);
        i = 0;
        while (i < 3) : (i += 1) accel_bias[i] *%= @as(c_long, accel_sens);
        _ = dmp_set_accel_bias(&accel_bias);
    }

    /// 对照 Read_DMP(): 从 DMP FIFO 读一帧，返回四元数（若本帧含四元数）。失败/无数据返回 null。
    pub fn readQuat(self: *Dmp) ?Quat {
        _ = self;
        var gyro: [3]i16 = undefined;
        var accel: [3]i16 = undefined;
        var quat: [4]c_long = undefined;
        var timestamp: c_ulong = 0;
        var sensors: i16 = 0;
        var more: u8 = 0;

        if (dmp_read_fifo(&gyro, &accel, &quat, &timestamp, &sensors, &more) != 0) return null;
        if ((sensors & WXYZ_QUAT) == 0) return null;

        return .{
            .w = @as(f32, @floatFromInt(quat[0])) / Q30,
            .x = @as(f32, @floatFromInt(quat[1])) / Q30,
            .y = @as(f32, @floatFromInt(quat[2])) / Q30,
            .z = @as(f32, @floatFromInt(quat[3])) / Q30,
        };
    }

    /// 对照 Read_DMP(): 由四元数算欧拉角（度）。无数据返回 null。
    pub fn readEuler(self: *Dmp) ?Euler {
        const q = self.readQuat() orelse return null;
        const q0 = q.w;
        const q1 = q.x;
        const q2 = q.y;
        const q3 = q.z;
        const rad2deg: f32 = 57.29578;
        const roll = std.math.asin(-2.0 * q1 * q3 + 2.0 * q0 * q2) * rad2deg;
        const pitch = std.math.atan2(2.0 * q2 * q3 + 2.0 * q0 * q1, -2.0 * q1 * q1 - 2.0 * q2 * q2 + 1.0) * rad2deg;
        const yaw = std.math.atan2(2.0 * (q1 * q2 + q0 * q3), q0 * q0 + q1 * q1 - q2 * q2 - q3 * q3) * rad2deg;
        return .{ .roll = roll, .pitch = pitch, .yaw = yaw };
    }
};

/// 便捷入口：用给定 I2C 总线创建 DMP 句柄。
pub fn init(i2c: i2c_soft.I2c) Dmp {
    return .{ .i2c = i2c };
}
