//! 引脚（与参考工程一致）:
//!   RST = PB3
//!   DC  = PA15   (RS)
//!   SCL = PB5
//!   SDA = PB4    (SDIN)
//!
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const font = @import("oled_font.zig");
const delay = @import("delay");

const Pin = hal.gpio.Pin;
const AFIO = microzig.chip.peripherals.AFIO;
const RCC = microzig.chip.peripherals.RCC;

/// SWJ_CFG 取值（原工程 JTAG_Set 的 mode 参数）。
/// 注意: 复位默认是 0b000 (JTAG+SWD 全开), 会占用 PA13/14/15 + PB3/4。
pub const SwjConfig = enum(u3) {
    /// JTAG+SWD 全开（复位默认）
    jtag_swd_enable = 0b000,
    /// 关 JTAG, 保留 SWD（释放 PB3/PB4/PA15, 仍可 SWD 调试）
    swd_enable = 0b001,
    /// JTAG+SWD 全关
    jtag_swd_disable = 0b010,
};

/// 对照原工程 `JTAG_Set(mode)`: 清 SWJ_CFG[26:24] 后写入 mode。
/// 原工程: `AFIO->MAPR &= 0xF8FFFFFF; AFIO->MAPR |= mode<<25;`
fn jtagSet(mode: SwjConfig) void {
    const mask: u32 = 0xF8FFFFFF; // 清 bit[26:24] (SWJ_CFG)
    const val: u32 = @as(u32, @intFromEnum(mode)) << 25;
    AFIO.MAPR.raw = (AFIO.MAPR.raw & mask) | val;
}

/// 释放 JTAG 占用的引脚（严格对照原工程 `MiniBalance.c` 的两步调用）:
///   `JTAG_Set(JTAG_SWD_DISABLE);  // 0b010 全关`
///   `JTAG_Set(SWD_ENABLE);        // 0b001 仅 SWD`
///
/// 本板 OLED 用到 PB3/PB4/PA15, 它们默认是 JTAG 复用脚,
/// 必须切到 `swd_enable`（仅 SWD）才能当普通 GPIO 用。
///
/// 注意: 必须**先写 0b010 再写 0b001**。参考手册规定 SWJ_CFG 不能
/// 从非零值直接跳到 0b000, 且直接单次写入不如经过中间态可靠。
pub fn disableJtagKeepSwd() void {
    // 使能 AFIO 时钟（APB2ENR.AFIOEN = bit0）
    RCC.APB2ENR.modify_one("AFIOEN", 1);
    // 两步写入（与参考工程完全一致）
    jtagSet(.jtag_swd_disable); // 0b010
    jtagSet(.swd_enable); // 0b001
}

/// 写命令 / 写数据标志（对照 OLED_CMD / OLED_DATA）。
pub const Cmd: u8 = 0;
pub const Data: u8 = 1;

/// 屏幕尺寸（SSD1306 128x64）。
pub const width: u8 = 128;
pub const height: u8 = 64;

/// 字体大小（对照 OLED_ShowChar 的 size 参数）。
pub const Font = enum {
    /// 6x12
    font_6x12,
    /// 8x16
    font_8x16,

    pub fn charWidth(self: Font) u8 {
        return switch (self) {
            .font_6x12 => 6,
            .font_8x16 => 8,
        };
    }
    pub fn charHeight(self: Font) u8 {
        return switch (self) {
            .font_6x12 => 12,
            .font_8x16 => 16,
        };
    }
};

/// OLED 句柄。持有 4 个控制引脚 + 显存。
pub const Oled = struct {
    rst: Pin,
    dc: Pin,
    scl: Pin,
    sda: Pin,
    /// 显存: 按列组织, gram[x][page] (与原工程 OLED_GRAM[128][8] 一致)
    gram: [width][height / 8]u8 = std.mem.zeroes([width][height / 8]u8),

    // ---------- 底层: 引脚操作 ----------

    inline fn rstLow(self: *Oled) void {
        self.rst.put(0);
    }
    inline fn rstHigh(self: *Oled) void {
        self.rst.put(1);
    }
    inline fn dcLow(self: *Oled) void {
        self.dc.put(0);
    }
    inline fn dcHigh(self: *Oled) void {
        self.dc.put(1);
    }
    inline fn sclLow(self: *Oled) void {
        self.scl.put(0);
    }
    inline fn sclHigh(self: *Oled) void {
        self.scl.put(1);
    }
    inline fn sdaLow(self: *Oled) void {
        self.sda.put(0);
    }
    inline fn sdaHigh(self: *Oled) void {
        self.sda.put(1);
    }

    /// 对照 OLED_WR_Byte(): 软件 SPI 写一个字节。
    /// `dat` 数据/命令, `mode` 用 Cmd/Data 指定。
    fn writeByte(self: *Oled, dat: u8, mode: u8) void {
        var d = dat;
        if (mode != 0) self.dcHigh() else self.dcLow();
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            self.sclLow();
            if ((d & 0x80) != 0) self.sdaHigh() else self.sdaLow();
            self.sclHigh();
            d <<= 1;
        }
        self.dcHigh();
    }

    /// 对照 OLED_Refresh_Gram(): 把显存刷到屏幕。
    pub fn refresh(self: *Oled) void {
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            self.writeByte(0xB0 + i, Cmd); // 页地址
            self.writeByte(0x00, Cmd); // 列低地址
            self.writeByte(0x10, Cmd); // 列高地址
            var n: u8 = 0;
            while (n < 128) : (n += 1) {
                self.writeByte(self.gram[n][i], Data);
            }
        }
    }

    /// 对照 OLED_Display_On()。
    pub fn displayOn(self: *Oled) void {
        self.writeByte(0x8D, Cmd);
        self.writeByte(0x14, Cmd);
        self.writeByte(0xAF, Cmd);
    }

    /// 对照 OLED_Display_Off()。
    pub fn displayOff(self: *Oled) void {
        self.writeByte(0x8D, Cmd);
        self.writeByte(0x10, Cmd);
        self.writeByte(0xAE, Cmd);
    }

    /// 对照 OLED_Clear()。
    pub fn clear(self: *Oled) void {
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            var n: u8 = 0;
            while (n < 128) : (n += 1) self.gram[n][i] = 0x00;
        }
        self.refresh();
    }

    /// 对照 OLED_DrawPoint(): t=1 填充, t=0 清空。
    pub fn drawPoint(self: *Oled, x: u8, y: u8, t: u8) void {
        if (x > 127 or y > 63) return;
        const pos = 7 - y / 8;
        const bx = y % 8;
        const temp: u8 = @as(u8, 1) << @intCast(7 - bx);
        if (t != 0) {
            self.gram[x][pos] |= temp;
        } else {
            self.gram[x][pos] &= ~temp;
        }
    }

    /// 对照 OLED_ShowChar(): 在 (x,y) 显示一个字符。
    /// `size` 用 Font 指定; mode=0 反白, 1 正常。
    pub fn showChar(self: *Oled, x_in: u8, y_in: u8, chr: u8, size: Font, mode: u8) void {
        var x = x_in;
        const y0 = y_in;
        var y = y_in;
        const idx: usize = if (chr >= ' ') chr - ' ' else 0;

        const glyph: []const u8 = switch (size) {
            .font_6x12 => &font.asc2_1206[idx],
            .font_8x16 => &font.asc2_1608[idx],
        };
        const snap = size.charHeight();

        for (glyph) |col| {
            var temp = col;
            var t1: u8 = 0;
            while (t1 < 8) : (t1 += 1) {
                if ((temp & 0x80) != 0) {
                    self.drawPoint(x, y, mode);
                } else {
                    self.drawPoint(x, y, if (mode != 0) 0 else 1);
                }
                temp <<= 1;
                y += 1;
                if (y - y0 == snap) {
                    y = y0;
                    x += 1;
                    break;
                }
            }
        }
    }

    /// 对照 oled_pow(): m 的 n 次方。
    fn pow(m: u8, n: u8) u32 {
        var result: u32 = 1;
        var e = n;
        while (e > 0) : (e -= 1) result *= m;
        return result;
    }

    /// 对照 OLED_ShowNumber(): 显示数字。
    pub fn showNumber(self: *Oled, x: u8, y: u8, num: u32, len: u8, size: Font) void {
        var enshow: u8 = 0;
        var t: u8 = 0;
        const step = size.charWidth(); // size/2 在 C 里是 6/2=3? 实际原码用 size/2，这里用半宽
        _ = step;
        while (t < len) : (t += 1) {
            const temp: u8 = @intCast((num / pow(10, len - t - 1)) % 10);
            if (enshow == 0 and t < len - 1) {
                if (temp == 0) {
                    self.showChar(x + (size.charWidth() / 2) * t, y, ' ', size, 1);
                    continue;
                } else {
                    enshow = 1;
                }
            }
            self.showChar(x + (size.charWidth() / 2) * t, y, temp + '0', size, 1);
        }
    }

    /// 对照 OLED_ShowString(): 显示以 0 结尾的字符串（用 6x12 字体）。
    pub fn showString(self: *Oled, x_in: u8, y_in: u8, s: []const u8) void {
        const max_x: u8 = 122;
        const max_y: u8 = 58;
        var x = x_in;
        var y = y_in;
        for (s) |c| {
            if (c == 0) break;
            if (x > max_x) {
                x = 0;
                y +%= 16;
            }
            if (y > max_y) {
                x = 0;
                y = 0;
                self.clear();
            }
            self.showChar(x, y, c, .font_6x12, 1);
            x +%= 8;
        }
    }

    /// 对照 OLED_Init(): 上电初始化 + 配置 SSD1306。
    /// 延时用 SysTick（`delay.delayMs`），故调用前需先 `delay.init(系统时钟)`。
    /// 不用 microzig 的 `hal.time`，以避免占用 TIM2（留给编码器等外设）。
    pub fn init(self: *Oled) void {
        // 复位脉冲
        self.rstLow();
        delay.delayMs(100);
        self.rstHigh();

        // SSD1306 初始化序列（与参考工程 OLED_Init 一致）
        self.writeByte(0xAE, Cmd); // 关闭显示
        self.writeByte(0xD5, Cmd);
        self.writeByte(80, Cmd);
        self.writeByte(0xA8, Cmd);
        self.writeByte(0x3F, Cmd);
        self.writeByte(0xD3, Cmd);
        self.writeByte(0x00, Cmd);
        self.writeByte(0x40, Cmd);
        self.writeByte(0x8D, Cmd);
        self.writeByte(0x14, Cmd);
        self.writeByte(0x20, Cmd);
        self.writeByte(0x02, Cmd);
        self.writeByte(0xA1, Cmd);
        self.writeByte(0xC0, Cmd);
        self.writeByte(0xDA, Cmd);
        self.writeByte(0x12, Cmd);
        self.writeByte(0x81, Cmd);
        self.writeByte(0xEF, Cmd);
        self.writeByte(0xD9, Cmd);
        self.writeByte(0xf1, Cmd);
        self.writeByte(0xDB, Cmd);
        self.writeByte(0x30, Cmd);
        self.writeByte(0xA4, Cmd);
        self.writeByte(0xA6, Cmd);
        self.writeByte(0xAF, Cmd); // 开启显示
        self.clear();
    }
};

/// 板载 OLED 的引脚定义（与参考工程一致）。
pub fn pinConfig() struct {
    rst: Pin,
    dc: Pin,
    scl: Pin,
    sda: Pin,
} {
    return .{
        .rst = Pin.from_port(.B, 3), // PB3
        .dc = Pin.from_port(.A, 15), // PA15
        .scl = Pin.from_port(.B, 5), // PB5
        .sda = Pin.from_port(.B, 4), // PB4
    };
}

/// 初始化板载 OLED 并返回句柄。
///
/// 注意: PB3/PB4 默认是 JTAG 复用脚 (JTDO/NJTRST)。
/// 若板上需要释放它们为普通 GPIO, 需在调用前关闭 JTAG 复用
/// （参考工程通过 `RCC_LSEConfig`/`BKP_TamperPinCmd` 间接处理）。
/// 具体视硬件接线而定。
pub fn initOled() Oled {
    // 关键: 释放 JTAG 占用的引脚（PB3/PB4/PA15），否则 OLED 无法工作。
    // 对应原工程 main() 里的 JTAG_Set(JTAG_SWD_DISABLE)/JTAG_Set(SWD_ENABLE)。
    disableJtagKeepSwd();

    // 关键: 使能 GPIOA/GPIOB 时钟（对照 C 里
    // RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA|GPIOB, ENABLE)）。
    // 不开时钟时 GPIO 寄存器写入无效。APB2ENR: GPIOA=bit2, GPIOB=bit3。
    RCC.APB2ENR.raw |= (1 << 2) | (1 << 3);
    _ = RCC.APB2ENR.raw;

    const cfg = pinConfig();

    cfg.rst.set_output_mode(.general_purpose_push_pull, .max_2MHz);
    cfg.dc.set_output_mode(.general_purpose_push_pull, .max_2MHz);
    cfg.scl.set_output_mode(.general_purpose_push_pull, .max_2MHz);
    cfg.sda.set_output_mode(.general_purpose_push_pull, .max_2MHz);

    var o = Oled{
        .rst = cfg.rst,
        .dc = cfg.dc,
        .scl = cfg.scl,
        .sda = cfg.sda,
    };
    o.init();
    return o;
}
