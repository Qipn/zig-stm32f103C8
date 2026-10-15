//! 按键扫描驱动（FIFO 版）。
//!   (1) 按键按下 (DOWN)
//!   (2) 按键弹起 (UP)
//!   (3) 长按键   (LONG)
//!   (4) 长按后自动连发 (repeat)
//!   (5) 按键事件存入 **FIFO**，主循环用 `getKey()` 取出
//!   (6) 支持**多键**，且单键事件要求"仅有该键按下"（可防组合键误触发）
//! 时间单位: 扫描周期 10ms 为 1 tick（与参考工程一致）。
//!   * 滤波 KEY_FILTER_TIME = 5  → 50ms 消抖
//!   * 长按 KEY_LONG_TIME   = 100 → 1s
//!
//! 硬件: 按键接 **PA5**，上拉输入，按下为低电平。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

const Pin = hal.gpio.Pin;
const RCC = microzig.chip.peripherals.RCC;

/// 滤波时间（单位: 扫描 tick，1 tick = 10ms）。5 → 50ms 消抖。
pub const KEY_FILTER_TIME: u8 = 5;

/// 默认长按时间（单位: 扫描 tick）。100 → 1s。0 表示不检测长按。
pub const KEY_LONG_TIME: u16 = 100;

/// FIFO 容量（参考工程 KEY_FIFO_SIZE = 10）。
pub const KEY_FIFO_SIZE: usize = 10;

/// 按键事件（对照参考工程 bsp_PutKey 里 3*i+1/2/3 的编码）。
pub const Event = enum {
    down, // 3*i+1
    up, // 3*i+2
    long, // 3*i+3
};

/// 一个按键事件 = 按键索引 + 事件类型。
pub const KeyEvent = struct {
    id: usize,
    event: Event,
};

/// 每个按键的状态（对照 KEY_T）。
const ButtonState = struct {
    count: u8 = KEY_FILTER_TIME / 2, // 滤波器计数器
    long_count: u16 = 0, // 长按计数器
    long_time: u16 = KEY_LONG_TIME, // 长按时间（tick），0 = 不检测长按
    state: u1 = 0, // 0 未按下, 1 按下
    repeat_speed: u8 = 0, // 连发周期，0 = 不连发
    repeat_count: u8 = 0, // 连发计数器
};

/// 生成 n 个默认按键状态（数组初始化）。
fn defaultBtnStates(comptime n: usize) [n]ButtonState {
    var a: [n]ButtonState = undefined;
    for (&a) |*b| b.* = .{};
    return a;
}

/// 按键扫描器。泛型参数 `n_keys` 为按键个数（编译期）。
///
/// 用法:
/// ```zig
/// var scanner = key_scan.Scanner(1){ .pins = .{Pin.from_port(.A, 5)} };
/// scanner.init();
/// // 每 10ms 调一次:
/// scanner.scan();
/// // 主循环取事件:
/// while (scanner.getKey()) |ev| { ... }
/// ```
pub fn Scanner(comptime n_keys: usize) type {
    return struct {
        const Self = @This();

        /// 各按键的 GPIO 引脚；active_level = 按下时的电平（上拉→低电平=0）。
        pins: [n_keys]Pin,
        active_level: u1 = 0,

        btn: [n_keys]ButtonState = defaultBtnStates(n_keys),
        fifo: [KEY_FIFO_SIZE]KeyEvent = undefined,
        read: usize = 0,
        write: usize = 0,
        read2: usize = 0,

        /// 对照 bsp_InitKey(): 使能 GPIO 时钟 + 配置上拉输入。
        pub fn init(self: *Self) void {
            for (self.pins) |pin| {
                // 使能该引脚端口时钟（microzig 的 set_*_mode 不会开时钟）。
                const port_index: u5 = @intCast(@backingInt(pin) / 16);
                const bit: u32 = @as(u32, 1) << (port_index + 2);
                RCC.APB2ENR.raw |= bit;
                _ = RCC.APB2ENR.raw & bit;

                // 上拉输入（参考工程用浮空输入 + 外部上拉；本项目按键上拉到 VCC 用内部上拉）
                pin.set_input_mode(.pull);
                pin.set_pull(if (self.active_level == 0) .up else .down);
            }
        }

        /// 对照 KeyPinActive(): 单个按键引脚是否处于"激活"（按下）状态。
        fn pinActive(self: *const Self, id: usize) bool {
            return self.pins[id].read() == self.active_level;
        }

        /// 对照 IsKeyDownFunc(): 该按键是否被按下。
        /// 单键（< n_keys）要求"只有它被按下"，以免组合键状态下误触发单键。
        fn isKeyDown(self: *const Self, id: usize) bool {
            var count: usize = 0;
            var save: usize = std.math.maxInt(usize);
            for (0..n_keys) |i| {
                if (self.pinActive(i)) {
                    count += 1;
                    save = i;
                }
            }
            return count == 1 and save == id;
        }

        /// 对照 bsp_DetectKey(): 检测一个按键（含消抖、长按、连发），产生事件入 FIFO。
        fn detect(self: *Self, i: usize) void {
            const p = &self.btn[i];
            if (self.isKeyDown(i)) {
                if (p.count < KEY_FILTER_TIME) {
                    p.count = KEY_FILTER_TIME;
                } else if (p.count < 2 * KEY_FILTER_TIME) {
                    p.count += 1;
                } else {
                    if (p.state == 0) {
                        p.state = 1;
                        self.putKey(.{ .id = i, .event = .down }); // 按下
                    }

                    if (p.long_time > 0) {
                        if (p.long_count < p.long_time) {
                            p.long_count += 1;
                            if (p.long_count == p.long_time) {
                                self.putKey(.{ .id = i, .event = .long }); // 长按
                            }
                        } else if (p.repeat_speed > 0) {
                            p.repeat_count += 1;
                            if (p.repeat_count >= p.repeat_speed) {
                                p.repeat_count = 0;
                                self.putKey(.{ .id = i, .event = .down }); // 连发
                            }
                        }
                    }
                }
            } else {
                if (p.count > KEY_FILTER_TIME) {
                    p.count = KEY_FILTER_TIME;
                } else if (p.count != 0) {
                    p.count -= 1;
                } else {
                    if (p.state == 1) {
                        p.state = 0;
                        self.putKey(.{ .id = i, .event = .up }); // 弹起
                    }
                }
                p.long_count = 0;
                p.repeat_count = 0;
            }
        }

        /// 对照 bsp_KeyScan10ms(): 扫描所有按键。**每 10ms 调用一次**。
        pub fn scan(self: *Self) void {
            for (0..n_keys) |i| self.detect(i);
        }

        /// 对照 bsp_PutKey(): 把一个事件压入 FIFO（也可用于模拟按键）。
        pub fn putKey(self: *Self, ev: KeyEvent) void {
            self.fifo[self.write] = ev;
            self.write += 1;
            if (self.write >= KEY_FIFO_SIZE) self.write = 0;
        }

        /// 对照 bsp_GetKey(): 取一个事件（无则返回 null）。
        pub fn getKey(self: *Self) ?KeyEvent {
            if (self.read == self.write) return null;
            const ev = self.fifo[self.read];
            self.read += 1;
            if (self.read >= KEY_FIFO_SIZE) self.read = 0;
            return ev;
        }

        /// 对照 bsp_GetKey2(): 用独立读指针取事件（第二消费者，如系统控制）。
        pub fn getKey2(self: *Self) ?KeyEvent {
            if (self.read2 == self.write) return null;
            const ev = self.fifo[self.read2];
            self.read2 += 1;
            if (self.read2 >= KEY_FIFO_SIZE) self.read2 = 0;
            return ev;
        }

        /// 对照 bsp_GetKeyState(): 1 表示按下，0 表示未按下。
        pub fn getKeyState(self: *const Self, id: usize) u1 {
            return self.btn[id].state;
        }

        /// 对照 bsp_SetKeyParam(): 设置某键的长按时间与连发速度。
        /// `long_time` 单位是 10ms（100 = 1s，0 = 不检测长按）；
        /// `repeat_speed` 单位是 10ms（6 = 60ms 连发一次，0 = 不连发）。
        pub fn setParams(self: *Self, id: usize, long_time: u16, repeat_speed: u8) void {
            self.btn[id].long_time = long_time;
            self.btn[id].repeat_speed = repeat_speed;
            self.btn[id].repeat_count = 0;
        }

        /// 对照 bsp_ClearKey(): 清空 FIFO。
        pub fn clear(self: *Self) void {
            self.read = self.write;
        }
    };
}

// ---------- 板级按键定义 ----------

/// 板载单按键（PA5，上拉，按下为低）—— 直接可用的扫描器类型。
pub const BoardKey = Scanner(1);

/// 便捷入口：初始化板载按键扫描器并返回。
pub fn initBoardKey() BoardKey {
    var s = BoardKey{ .pins = .{hal.gpio.Pin.from_port(.A, 5)} };
    s.init();
    return s;
}
