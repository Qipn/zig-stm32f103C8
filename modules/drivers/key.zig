//! 硬件: 按键接 **PA5**，**上拉输入**，按下为**低电平**（对照 KEY = PAin(5)，
//! 与 C 工程一样，这些扫描函数都**不是中断驱动**，需要调用方**周期性调用**，
//! 且调用周期与函数内部的时间参数要匹配（见各函数文档）。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

const Pin = hal.gpio.Pin;
const RCC = microzig.chip.peripherals.RCC;

/// KEY_Scan 的返回值（对照参考工程 key.h 的枚举）。
pub const Event = enum(u2) {
    stateless, // key_stateless
    single, // single_click
    double, // double_click
    long, // long_click
};

/// 一个按键的句柄。
///
/// 采用句柄风格（对照参考工程的"全局引脚 + 静态状态"）：
/// 引脚由调用方持有；扫描状态存在本结构体内，因此**每个按键可独立扫描**。
pub const Key = struct {
    pin: Pin,
    /// true = 按下时读低电平（上拉输入）。参考工程即如此。
    active_low: bool = true,

    // ---- click() / click_N_Double() 的状态（对照 C 里的 static 变量）----
    flag_key: u8 = 1, // click: 松开标志
    cnt_flag_key: u8 = 0, // click_N_Double: 第一次按下标志
    cnt_count_key: u8 = 0, // click_N_Double: 按下一次标记
    cnt_double_key: u8 = 0, // click_N_Double: 已按下的次数
    cnt_count_single: u16 = 0, // click_N_Double: 单次等待计时
    cnt_forever: u16 = 0, // click_N_Double: 长按计时

    // ---- Long_Press() 的状态 ----
    lp_count: u16 = 0,
    lp_flag: u8 = 0,

    // ---- KEY_Scan() 状态机 ----
    ks_time_core: u16 = 0,
    ks_long_time: u16 = 0,
    ks_press_flag: u8 = 0,
    ks_check_once: u8 = 0,
    ks_delay1: u16 = 0,
    ks_delay2: u16 = 0,

    /// 配置引脚为上拉输入，使能 GPIO 时钟。
    /// 对照 KEY_Init(): RCC_APB2PeriphClockCmd(GPIOA) + GPIO_Mode_IPU。
    pub fn init(self: Key) Key {
        // 使能该引脚所在端口时钟（同 led.zig：microzig 的 set_input_mode 不会开时钟）。
        const port_index: u5 = @intCast(@backingInt(self.pin) / 16);
        const bit: u32 = @as(u32, 1) << (port_index + 2);
        RCC.APB2ENR.raw |= bit;
        _ = RCC.APB2ENR.raw & bit;

        // 上拉输入：CNF=10,MODE=00；再置 ODR=1 选中"上拉"（对应 IPU）。
        self.pin.set_input_mode(.pull);
        self.pin.set_pull(.up);
        return self;
    }

    /// 读取按键是否被按下（对照参考工程 `KEY==0`）。
    pub fn isPressed(self: Key) bool {
        const level = self.pin.read();
        return if (self.active_low) level == 0 else level == 1;
    }

    /// 对照 click(): 单击扫描，返回值是否检测到一次"按下"。
    ///
    /// 需要**周期性调用**（例如每 10~20ms 一次）。返回 1 表示本次调用检测到
    /// 一个按下沿（类似参考工程，按下即返回，不等松开）。
    pub fn click(self: *Key) bool {
        if (self.flag_key != 0 and self.isPressed()) {
            self.flag_key = 0;
            return true;
        } else if (!self.isPressed()) {
            self.flag_key = 1;
        }
        return false;
    }

    /// 对照 click_N_Double(time): 单击/双击扫描。
    ///
    /// 返回 0=无动作, 1=单击, 2=双击。
    /// 需要**周期性调用**；`time` 是等待双击的"扫描次数"（10ms 扫描一次时，
    /// 例如 time=30 表示 300ms 内再按才算双击）。
    pub fn clickNDouble(self: *Key, time: u8) u2 {
        if (self.isPressed()) {
            self.cnt_forever +%= 1; // 长按标志未置位时累加
        } else {
            self.cnt_forever = 0;
        }

        // 第一次按下
        if (self.isPressed() and self.cnt_flag_key == 0) {
            self.cnt_flag_key = 1;
        }

        if (self.cnt_count_key == 0) {
            if (self.cnt_flag_key == 1) {
                self.cnt_double_key +%= 1;
                self.cnt_count_key = 1; // 标记按下一次
            }
            if (self.cnt_double_key == 2) { // 按下两次 → 双击
                self.cnt_double_key = 0;
                self.cnt_count_single = 0;
                return 2;
            }
        }

        if (!self.isPressed()) {
            self.cnt_flag_key = 0;
            self.cnt_count_key = 0;
        }

        if (self.cnt_double_key == 1) {
            self.cnt_count_single +%= 1;
            if (self.cnt_count_single > time and self.cnt_forever < time) {
                self.cnt_double_key = 0;
                self.cnt_count_single = 0;
                return 1; // 超时未再按 → 单击
            }
            if (self.cnt_forever > time) {
                self.cnt_double_key = 0;
                self.cnt_count_single = 0;
            }
        }
        return 0;
    }

    /// 对照 Long_Press(): 长按检测，返回是否触发一次长按（约 2s）。
    ///
    /// 需要**每 10ms 调用一次**（函数内部按 >200 次判定 ≈ 2s）。
    pub fn longPress(self: *Key) bool {
        if (self.lp_flag == 0 and self.isPressed()) {
            self.lp_count +%= 1;
        } else {
            self.lp_count = 0;
        }

        if (self.lp_count > 200) { // 10ms × 200 = 2s
            self.lp_flag = 1;
            self.lp_count = 0;
            return true;
        }
        if (self.lp_flag == 1) {
            self.lp_flag = 0;
        }
        return false;
    }

    /// 对照 KEY_Scan(Frequency, filter_times): 单击/双击/长按状态机（推荐用法）。
    ///
    /// 返回本次识别到的按键事件。
    ///
    /// * `frequency`    该函数的调用频率（Hz），如 100 表示每 10ms 调用一次。
    /// * `filter_times` 数字滤波：连续调用 `filter_times` 次都读到同电平才采信，
    ///                  用于消抖。例如 frequency=100, filter_times=2。
    ///
    /// 时间阈值（对照参考工程）: 长按 1s、双击需在 50~500ms 内再按下。
    pub fn keyScan(self: *Key, frequency: u16, filter_times: u16) Event {
        if (frequency == 0) return .stateless;
        // 对照 C: Count_time = (1/freq)*1000  —— 每计 1 次代表的毫秒数
        const ms_per_count: f32 = (1.0 / @as(f32, @floatFromInt(frequency))) * 1000.0;
        const long_threshold: u16 = @intFromFloat(600.0 / ms_per_count); // 长按 1s
        const double_lo: u16 = @intFromFloat(50.0 / ms_per_count);
        const double_hi: u16 = @intFromFloat(500.0 / ms_per_count);

        if (self.ks_check_once != 0) { // 完成一次识别 → 清空所有状态
            self.ks_press_flag = 0;
            self.ks_time_core = 0;
            self.ks_long_time = 0;
            self.ks_delay1 = 0;
            self.ks_delay2 = 0;
        }
        if (self.ks_check_once != 0 and !self.isPressed()) {
            self.ks_check_once = 0; // 弹起后开启下一次扫描
        }

        if (self.isPressed() and self.ks_check_once == 0) { // 按键扫描
            self.ks_press_flag = 1;
            self.ks_delay1 +%= 1;
            if (self.ks_delay1 > filter_times) {
                self.ks_delay1 = 0;
                self.ks_long_time +%= 1;
            }
        }

        if (self.ks_long_time > long_threshold) {
            self.ks_check_once = 1;
            return .long;
        }

        // 按下一次又弹起后，开启走时
        if (self.ks_press_flag != 0 and !self.isPressed()) {
            self.ks_delay2 +%= 1;
            if (self.ks_delay2 > filter_times) {
                self.ks_delay2 = 0;
                self.ks_time_core +%= 1;
            }
        }

        if (self.ks_press_flag != 0 and
            self.ks_time_core > double_lo and self.ks_time_core < double_hi)
        {
            if (self.isPressed()) { // 50~500ms 内再次按下 → 双击
                self.ks_check_once = 1;
                return .double;
            }
        } else if (self.ks_press_flag != 0 and self.ks_time_core > double_hi) {
            self.ks_check_once = 1; // 超过 500ms 未再按 → 单击
            return .single;
        }

        return .stateless;
    }
};

// ---------- 板级按键定义 ----------

/// 板载按键：接在 PA5，上拉输入，按下为低电平。
pub const board_key = Key{ .pin = blk: {
    const gpio = hal.gpio;
    break :blk gpio.Pin.from_port(.A, 5);
} };

/// 便捷入口：初始化板载按键并返回句柄。
pub fn initBoardKey() Key {
    return board_key.init();
}
