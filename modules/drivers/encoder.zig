//! 硬件（B570）:
//!   * 左轮: **PA0 = TIM2_CH1**, **PA1 = TIM2_CH2**（浮空输入）
//!   * 右轮: **PB6 = TIM4_CH1**, **PB7 = TIM4_CH2**（浮空输入）
//!
//! 为什么直接写寄存器（不用 microzig HAL）:
//!   编码器模式需精细设置 SMCR.SMS / CCMR 输入映射 / CCER 极性 / 输入滤波，
//!   直接写寄存器与参考工程一致，最清晰可靠。
//!
//! 计数器: 16 位，周期 65535（ENCODER_TIM_PERIOD）。`read()` 返回带符号差值。
//!   TIM2 已不再被 `hal.time` 占用（OLED 已改用 SysTick），故可安全用作编码器。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

const Pin = hal.gpio.Pin;
const RCC = microzig.chip.peripherals.RCC;

/// 计数周期（对照 ENCODER_TIM_PERIOD = 65535，F103 定时器 16 位）。
pub const ENCODER_TIM_PERIOD: u16 = 65535;

/// 编码器句柄（泛型参数 `inst` 为定时器实例：.TIM2 / .TIM4）。
pub fn Encoder(comptime inst: enum { TIM2, TIM4 }) type {
    return struct {
        const Self = @This();
        /// 该编码器两个输入引脚（CH1/CH2）。
        ch1: Pin,
        ch2: Pin,

        const regs = switch (inst) {
            .TIM2 => microzig.chip.peripherals.TIM2,
            .TIM4 => microzig.chip.peripherals.TIM4,
        };

        /// 对照 Encoder_Init_TIM2/4(): 配置两个引脚为浮空输入 + 定时器编码器模式。
        pub fn init(self: Self) Self {
            // 引脚端口时钟（APB2ENR: GPIOA=bit2, GPIOB=bit3）
            const port_bit: u32 = if (@backingInt(self.ch1) / 16 == 0) (1 << 2) else (1 << 3);
            RCC.APB2ENR.raw |= port_bit;
            _ = RCC.APB2ENR.raw;

            // 浮空输入（对照 GPIO_Mode_IN_FLOATING）
            self.ch1.set_input_mode(.floating);
            self.ch2.set_input_mode(.floating);

            // 定时器时钟：TIM2 在 APB1（APB1ENR bit0），TIM4 在 APB1（APB1ENR bit2）
            const tim_bit: u32 = switch (inst) {
                .TIM2 => 1 << 0,
                .TIM4 => 1 << 2,
            };
            RCC.APB1ENR.raw |= tim_bit;
            _ = RCC.APB1ENR.raw;

            // 时基：PSC=0, ARR=65535（对照 TIM_TimeBaseInit）
            regs.PSC = 0;
            regs.ARR.raw = ENCODER_TIM_PERIOD;

            // 编码器模式 3（SMS=011，在 TI1/TI2 双边沿计数）
            // 对照 TIM_EncoderInterfaceConfig(TIMx, TIM_EncoderMode_TI12, Rising, Rising)
            //   上升沿 → CC1P=0, CC2P=0
            regs.SMCR.raw = (0b011); // SMS = 011

            // CCMR1: 通道1/2 映射为输入（CC1S=01, CC2S=01），输入滤波 ICF=10(0b1010)。
            // 位: CC1S[1:0]=01, IC1PSC[3:2]=00, IC1F[7:4]=1010;
            //     CC2S[9:8]=01, IC2PSC[11:10]=00, IC2F[15:12]=1010
            regs.CCMR_Input[0].raw = (0b01) | (0b01 << 8) | (@as(u32, 10) << 4) | (@as(u32, 10) << 12);

            // CCER: **不使能** CC1E/CC2E（编码器模式下 CCxE 应为 0，只用输入通道；
            // 对照 SPL 的 TIM_EncoderInterfaceConfig 仅设置极性位、不动 CCxE），
            // 两个输入均为上升沿（CC1P=CC2P=0）→ CCER 保持 0。
            regs.CCER.raw = 0;

            // 清更新标志，计数器清零，使能
            regs.EGR.raw = 1; // UG
            regs.CNT.raw = 0;
            regs.CR1.raw |= 1; // CEN=1

            return self;
        }

        /// 对照 Read_Encoder(TIMX): 读 CNT（按有符号 16 位解释）并清零。
        /// 返回单位时间内的脉冲数（带方向）。
        pub fn read(self: Self) i16 {
            _ = self;
            const v: u16 = @truncate(regs.CNT.raw);
            regs.CNT.raw = 0; // 读后清零，供下一周期测速
            return @bitCast(v);
        }

        /// 只读计数（不清零）。
        pub fn peek(self: Self) i16 {
            _ = self;
            return @bitCast(@as(u16, @truncate(regs.CNT.raw)));
        }
    };
}

/// 左轮编码器（TIM2，PA0/PA1）。
pub const left_encoder = Encoder(.TIM2){
    .ch1 = Pin.from_port(.A, 0),
    .ch2 = Pin.from_port(.A, 1),
};

/// 右轮编码器（TIM4，PB6/PB7）。
pub const right_encoder = Encoder(.TIM4){
    .ch1 = Pin.from_port(.B, 6),
    .ch2 = Pin.from_port(.B, 7),
};

/// 便捷入口：初始化左右两个编码器。
pub fn initBoardEncoders() struct { left: @TypeOf(left_encoder), right: @TypeOf(right_encoder) } {
    return .{
        .left = left_encoder.init(),
        .right = right_encoder.init(),
    };
}
