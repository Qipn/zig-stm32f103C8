//! 这些功能被映射为 `Led` 结构体的方法；区别在于 Zig 用**句柄**而非
//! "全局状态 + 数字序号索引"，从而:
//!   * 无隐藏全局可变状态
//!   * 引脚在编译期已知，无运行时越界
//!   * 调用方显式持有句柄，生命周期清晰

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

const RCC = microzig.chip.peripherals.RCC;

/// 一个 LED 的句柄。
///
/// 该类型是零成本抽象：`Pin` 本身是 `enum(usize)`，`active_low` 是编译期常量，
/// 整个结构体可被完全内联，无运行时开销。
pub const Led = struct {
    pin: hal.gpio.Pin,
    /// 编译期确定：true = 低电平点亮（参考工程 74HC574 即如此）
    active_low: bool = false,

    /// 配置引脚为推挽输出，并熄灭（对照 bsp_InitLed 对单个 LED 的处理）。
    /// 返回配置好的句柄。
    pub fn init(self: Led) Led {
        // 关键: 先使能该引脚所在端口的时钟。
        // 对照 C: RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOx, ENABLE)。
        // 不开时钟时 GPIO 寄存器写入被忽略，LED 不会亮。
        // APB2ENR 里 GPIOA..G 对应 bit2..bit8（与 microzig pins.zig 一致）。
        const port_index: u5 = @intCast(@backingInt(self.pin) / 16);
        const bit: u32 = @as(u32, 1) << (port_index + 2);
        RCC.APB2ENR.raw |= bit;
        _ = RCC.APB2ENR.raw & bit; // 读回，确保写入生效

        self.pin.set_output_mode(.general_purpose_push_pull, .max_50MHz);
        self.off();
        return self;
    }

    /// 点亮（对照 bsp_LedOn）。
    pub fn on(self: Led) void {
        self.pin.put(self.levelFor(true));
    }

    /// 熄灭（对照 bsp_LedOff）。
    pub fn off(self: Led) void {
        self.pin.put(self.levelFor(false));
    }

    /// 翻转（对照 bsp_LedToggle）。
    pub fn toggle(self: Led) void {
        self.pin.toggle();
    }

    /// 是否点亮（对照 bsp_IsLedOn）。
    pub fn isOn(self: Led) bool {
        return self.pin.read() == self.levelFor(true);
    }

    /// 根据极性把逻辑状态（亮/灭）转成引脚电平。
    inline fn levelFor(self: Led, want_on: bool) u1 {
        const high: u1 = if (want_on) 1 else 0;
        return if (self.active_low) 1 - high else high;
    }
};

// ---------- 板级 LED 定义 ----------

/// 板载 LED：接在 PA4，高电平点亮。
pub const board_led = Led{ .pin = blk: {
    const gpio = hal.gpio;
    break :blk gpio.Pin.from_port(.A, 4);
} };

/// 便捷入口：初始化板载 LED 并返回句柄。
pub fn initBoardLed() Led {
    return board_led.init();
}
