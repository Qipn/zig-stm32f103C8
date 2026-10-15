//! 硬件: **PA6 = ADC1_IN6**（电池分压采样）。分压比约 1/11（见参考工程公式）。
//!
//! 为什么直接写寄存器（不用 microzig HAL）:
//!   microzig 的 `AdvancedADC.enable()` 内部调用 `hal.time.sleep_us`，
//!   会依赖 time 子系统（占用 TIM2）。本项目约定摆脱 `hal.time`（TIM2 留给编码器），
//!   故直接配置 ADC1 寄存器，与参考工程一致。
//!
//! 时钟: ADC 时钟 = PCLK2/分频。参考工程用 PCLK2/6（72M/6=12MHz ≤ 14MHz）。
//!   本板 PCLK2=8MHz，/6 → 1.33MHz，安全。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

const Pin = hal.gpio.Pin;
const RCC = microzig.chip.peripherals.RCC;
const ADC1 = microzig.chip.peripherals.ADC1;

/// 电池采样通道（PA6 = ADC 通道 6）。
pub const BATTERY_CHANNEL: u5 = 6;

/// ADC 句柄。
pub const Adc = struct {
    /// 上次初始化用的通道（默认电池通道）。
    channel: u5 = BATTERY_CHANNEL,

    /// 对照 Adc_Init(): 使能 ADC1 时钟、PA6 模拟输入、设分频、校准。
    pub fn init(self: Adc) Adc {
        // 1. 使能 GPIOA(bit2) + ADC1(bit9) 时钟（APB2ENR）
        RCC.APB2ENR.raw |= (1 << 2) | (1 << 9);
        _ = RCC.APB2ENR.raw;

        // 2. ADC 时钟分频 = PCLK2 / 6（RCC_CFGR.ADCPRE = 0b10）
        //    RCC_CFGR bit[15:14]: 00=/2, 01=/4, 10=/6, 11=/8
        RCC.CFGR.raw &= ~(@as(u32, 0b11) << 14);
        RCC.CFGR.raw |= (@as(u32, 0b10) << 14);

        // 3. PA6 模拟输入（STM32F1: CNF=00, MODE=00 = analog）
        Pin.from_port(.A, 6).set_input_mode(.analog);

        // 4. 复位 ADC1 控制寄存器
        ADC1.CR2.raw = 0;

        // 5. 上电 + 校准（对照 ADC_Cmd/ResetCalibration/StartCalibration）
        ADC1.CR2.modify(.{ .ADON = 1 }); // 使能 ADC
        self.smallDelay();

        ADC1.CR2.modify(.{ .RSTCAL = 1 }); // 复位校准
        while (ADC1.CR2.read().RSTCAL == 1) {}
        ADC1.CR2.modify(.{ .CAL = 1 }); // 开始校准
        while (ADC1.CR2.read().CAL == 1) {}

        // 6. 转换由软件触发（EXTSEL=SWSTART=0b111, EXTTRIG=1）
        ADC1.CR2.modify(.{ .EXTSEL = 0b111, .EXTTRIG = 1 });

        return self;
    }

    inline fn smallDelay(self: Adc) void {
        _ = self;
        var i: u32 = 0;
        while (i < 1000) : (i += 1) asm volatile ("nop");
    }

    /// 对照 Get_Adc(ch): 软件触发单次转换，返回 12 位结果。
    /// 采样时间 239.5 周期（对照 ADC_SampleTime_239Cycles5）。
    pub fn readChannel(self: *Adc, ch: u5) u16 {
        _ = self;
        // 规则组序列 = 1 个转换，通道 = ch
        ADC1.SQR1.modify(.{ .L = 0 }); // L=0 表示 1 个转换
        ADC1.SQR3.modify(.{ .@"SQ[0]" = ch });

        // 采样时间：SMPR2 每通道 3 位，值 7 = 239.5 周期。
        // 通道 <10 用 SMPR2，>=10 用 SMPR1。位偏移 = ch*3。
        const rate: u32 = 7;
        if (ch < 10) {
            const shift: u5 = @intCast(ch * 3);
            ADC1.SMPR2.raw = (ADC1.SMPR2.raw & ~(@as(u32, 0b111) << shift)) | (rate << shift);
        } else {
            const shift: u5 = @intCast((ch - 10) * 3);
            ADC1.SMPR1.raw = (ADC1.SMPR1.raw & ~(@as(u32, 0b111) << shift)) | (rate << shift);
        }

        // 软件触发
        ADC1.CR2.modify(.{ .SWSTART = 1 });
        while (ADC1.SR.read().EOC == 0) {}
        return ADC1.DR.read().DATA; // 读 DR 会清 EOC
    }

    /// 便捷：读电池通道。
    pub fn readBatteryRaw(self: *Adc) u16 {
        return self.readChannel(self.channel);
    }

    /// 对照 Get_battery_volt(): 电池电压，单位 mV。
    /// 公式: adc * 3.3 * 11 * 100 / 4096（电阻分压 ~1/11）。
    pub fn batteryVoltMv(self: *Adc) i32 {
        const adc = self.readBatteryRaw();
        return @intCast(@divTrunc(@as(i32, adc) * 330 * 11, 4096));
    }
};

/// 便捷入口：初始化 ADC 并返回句柄。
pub fn initBoardAdc() Adc {
    return (Adc{}).init();
}
