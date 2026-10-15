//! 硬件:
//!   * PWM:  **PA8 = TIM1_CH1 (PWMA)**, **PA11 = TIM1_CH4 (PWMB)**
//!   * 方向: PB12=BIN2, PB13=BIN1, PB14=AIN1, PB15=AIN2
//!
//! 为什么直接写寄存器（不用 microzig HAL）:
//!   microzig 的 timer HAL 只覆盖通用定时器（TIM2~5, `TIM_GP16`），
//!   **不包含高级定时器 TIM1（`TIM_ADV`）**。故 TIM1 必须直接配置寄存器
//!   （也与参考工程的寄存器风格一致）。关键点是高级定时器还需使能 `BDTR.MOE`。
//!
//! 说明: 定时器时钟 8MHz（复位默认 HSI），PSC/ARR 决定 PWM 频率。
//!   参考工程 main() 里用 `MiniBalance_PWM_Init(7199, 0)` 之类，本模块提供默认值。

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

const Pin = hal.gpio.Pin;
const RCC = microzig.chip.peripherals.RCC;
const TIM1 = microzig.chip.peripherals.TIM1;

/// 电机句柄：持有两路 PWM 与 4 个方向脚。
///
/// 板级默认映射（B570）:
///   A 路: PWM=PA8(TIM1_CH1), AIN1=PB14, AIN2=PB15
///   B 路: PWM=PA11(TIM1_CH4), BIN1=PB13, BIN2=PB12
pub const Motor = struct {
    ain1: Pin,
    ain2: Pin,
    bin1: Pin,
    bin2: Pin,
    /// PWM 自动重载值（对应 TIM1->ARR），决定满速对应的比较值。
    arr: u16 = 7199,

    /// 对照 MiniBalance_PWM_Init(arr, psc): 配置 TIM1 PWM + 方向脚。
    ///
    /// `arr` 自动重载值，`psc` 预分频。PWM 频率 = 定时器时钟 / ((arr+1)*(psc+1))。
    pub fn init(self: Motor, psc: u16) Motor {
        return self.initWithArr(self.arr, psc);
    }

    pub fn initWithArr(self: Motor, arr: u16, psc: u16) Motor {
        // ---- 1. 方向脚 PB12~PB15 推挽输出（对照 MiniBalance_Motor_Init）----
        // 使能 GPIOB 时钟（APB2ENR bit3）
        RCC.APB2ENR.raw |= (1 << 3);
        _ = RCC.APB2ENR.raw;

        inline for (.{ self.ain1, self.ain2, self.bin1, self.bin2 }) |p| {
            p.set_output_mode(.general_purpose_push_pull, .max_50MHz);
            p.put(0);
        }

        // ---- 2. TIM1 时钟 + PWM 引脚复用推挽 ----
        // TIM1 在 APB2（APB2ENR.TIM1EN = bit11）；GPIOA 时钟 bit2
        RCC.APB2ENR.raw |= (1 << 11) | (1 << 2);
        _ = RCC.APB2ENR.raw;

        // PA8 / PA11 复用推挽输出（对照 GPIO_Mode_AF_PP）
        Pin.from_port(.A, 8).set_output_mode(.alternate_function_push_pull, .max_50MHz);
        Pin.from_port(.A, 11).set_output_mode(.alternate_function_push_pull, .max_50MHz);

        // ---- 3. 时基（对照 TIM_TimeBaseInit）----
        // 先关 CEN，写 PSC/ARR，开 ARR 预装载
        TIM1.CR1.raw &= ~@as(u16, 1 << 0); // CEN=0
        TIM1.PSC = psc;
        TIM1.ARR.raw = arr;
        TIM1.CR1.raw |= (1 << 7); // ARPE=1（ARR 预装载）
        TIM1.EGR.raw = 1; // UG=1，更新预装载

        // ---- 4. 输出比较（对照 TIM_OC1Init / TIM_OC4Init，PWM 模式1）----
        // 注意: microzig 把 TIM_ADV 的 CCMR1/CCMR2 只声明为 `CCMR_Input[2]`（输入模式别名），
        //   但其底层寄存器地址就是 CCMR1(0x18)/CCMR2(0x1C)。写输出模式用 `.raw` 即可。
        // CCMR1 低 8 位对应通道1: OC1M=[6:4]=110(PWM1), OC1PE=[3]=1
        TIM1.CCMR_Input[0].raw = (0b110 << 4) | (1 << 3);
        // CCMR2 通道4: OC4M=[14:12]=110, OC4PE=[11]=1
        TIM1.CCMR_Input[1].raw = (0b110 << 12) | (1 << 11);

        // CCER: CC1E=bit0, CC4E=bit12（输出使能），极性高
        TIM1.CCER.raw |= (1 << 0) | (1 << 12);

        // 初始占空比为 0
        TIM1.CCR[0].raw = 0;
        TIM1.CCR[3].raw = 0;

        // ---- 5. 高级定时器：主输出使能（MOE）----
        // 对照 TIM_CtrlPWMOutputs(TIM1, ENABLE)：BDTR.MOE=1（bit15）
        TIM1.BDTR.raw |= (1 << 15);

        // ---- 6. 启动 ----
        TIM1.CR1.raw |= (1 << 0); // CEN=1

        return .{ .ain1 = self.ain1, .ain2 = self.ain2, .bin1 = self.bin1, .bin2 = self.bin2, .arr = arr };
    }

    /// 停止（两路 PWM=0，方向清零）。
    pub fn stop(self: Motor) void {
        TIM1.CCR[0].raw = 0;
        TIM1.CCR[3].raw = 0;
        self.ain1.put(0);
        self.ain2.put(0);
        self.bin1.put(0);
        self.bin2.put(0);
    }

    /// 设置 A 路电机：`pwm` 为带符号值（正/负 = 正反转，绝对值 = 占空比 0..arr）。
    /// 对照 PWMA + AIN1/AIN2 的方向逻辑。
    pub fn setA(self: Motor, pwm: i32) void {
        if (pwm >= 0) {
            self.ain1.put(1);
            self.ain2.put(0);
        } else {
            self.ain1.put(0);
            self.ain2.put(1);
        }
        TIM1.CCR[0].raw = @intCast(@min(@as(u32, @intCast(if (pwm < 0) -pwm else pwm)), self.arr));
    }

    /// 设置 B 路电机（对照 PWMB + BIN1/BIN2）。
    pub fn setB(self: Motor, pwm: i32) void {
        if (pwm >= 0) {
            self.bin1.put(1);
            self.bin2.put(0);
        } else {
            self.bin1.put(0);
            self.bin2.put(1);
        }
        TIM1.CCR[3].raw = @intCast(@min(@as(u32, @intCast(if (pwm < 0) -pwm else pwm)), self.arr));
    }

    /// 同时设置两路（对照主控制里对 A/B 的赋值）。
    pub fn set(self: Motor, a: i32, b: i32) void {
        self.setA(a);
        self.setB(b);
    }
};

/// 板级电机映射（B570）: A=PWM PA8/AIN1 PB14/AIN2 PB15; B=PWM PA11/BIN1 PB13/BIN2 PB12。
pub const board_motor = Motor{
    .ain1 = Pin.from_port(.B, 14),
    .ain2 = Pin.from_port(.B, 15),
    .bin1 = Pin.from_port(.B, 13),
    .bin2 = Pin.from_port(.B, 12),
};

/// 便捷入口：初始化板载电机（arr=7199, psc=0）。
pub fn initBoardMotor() Motor {
    return board_motor.initWithArr(7199, 0);
}
