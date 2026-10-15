//! 与 microzig `hal.time.sleep_ms` 的区别:
//!   * microzig 用「定时器中断 + time 子系统」, 需先 init_timer 且时钟模型要对;
//!   * 本模块直接用 Cortex-M3 的 SysTick, **轮询 COUNTFLAG**, 不依赖中断,
//!     不依赖 microzig 的时钟假设 —— 更简单、更可靠。
//!
//! SysTick 是 Cortex-M 内核外设, 地址固定 0xE000E010, 无需开 RCC 时钟。

const std = @import("std");
const microzig = @import("microzig");

// Cortex-M3 SysTick 寄存器
const SYST_CSR: *volatile u32 = @ptrFromInt(0xE000E010); // 控制与状态
const SYST_RVR: *volatile u32 = @ptrFromInt(0xE000E014); // 重装载值
const SYST_CVR: *volatile u32 = @ptrFromInt(0xE000E018); // 当前值

const CSR_ENABLE: u32 = 1 << 0;
const CSR_CLKSOURCE: u32 = 1 << 2; // 1=处理器时钟, 0=处理器时钟/8
const CSR_COUNTFLAG: u32 = 1 << 16;

/// 每微秒的 SysTick 节拍数（fac_us）。由 init() 设置。
var fac_us: u32 = 0;

/// 对照 delay_init()：配置 SysTick 时钟源为 HCLK/8，计算 fac_us。
///
/// `system_clock` 传**实际的系统时钟频率**（Hz）。
/// 注意: 不要用 microzig 的 rcc.get_clock() 猜——它可能返回编译期假定值。
/// 本板跑复位默认 HSI 8MHz，故一般传 8_000_000。
pub fn init(system_clock: u32) void {
    // SysTick 时钟 = HCLK / 8
    SYST_CSR.* &= ~CSR_CLKSOURCE; // CLKSOURCE = 0 → HCLK/8

    // fac_us = SYSCLK / 8000000  （即每 us 有多少个 1/8 HCLK 节拍）
    fac_us = system_clock / 8_000_000;
    if (fac_us == 0) fac_us = 1; // 防止 8MHz 以下算出 0
}

/// 对照 delay_us(): 微秒级阻塞延时（轮询 COUNTFLAG，不用中断）。
pub fn delayUs(nus: u32) void {
    const load = nus * fac_us;
    SYST_RVR.* = load & 0x00FFFFFF; // 24 位重装载值
    SYST_CVR.* = 0; // 清当前值
    SYST_CSR.* |= CSR_ENABLE; // 启动倒数

    // 等待 COUNTFLAG（bit16）置位 = 倒数到 0
    while (true) {
        const csr = SYST_CSR.*;
        if ((csr & CSR_ENABLE) == 0) break; // 异常保护
        if ((csr & CSR_COUNTFLAG) != 0) break;
    }

    SYST_CSR.* &= ~CSR_ENABLE; // 关闭计数器
    SYST_CVR.* = 0; // 清当前值
}

/// 对照 delay_ms(): 毫秒级阻塞延时。
///
/// 注意 LOAD 是 24 位: 单次最大延时约 (0xFFFFFF/8) 个 HCLK 周期。
/// 8MHz 下最长约 16.7s；为通用起见，超过单次上限时循环多次。
pub fn delayMs(nms: u32) void {
    const fac_ms = fac_us * 1000;
    const max_ms: u32 = 0x00FFFFFF / fac_ms; // 单次能延的最大 ms

    var remain = nms;
    if (max_ms == 0) {
        // fac_ms 太大（极少见），退化为 us 循环
        while (remain > 0) : (remain -= 1) delayUs(1000);
        return;
    }

    while (remain > 0) {
        const chunk = @min(remain, max_ms);
        const load = chunk * fac_ms;

        SYST_RVR.* = load & 0x00FFFFFF;
        SYST_CVR.* = 0;
        SYST_CSR.* |= CSR_ENABLE;

        while (true) {
            const csr = SYST_CSR.*;
            if ((csr & CSR_ENABLE) == 0) break;
            if ((csr & CSR_COUNTFLAG) != 0) break;
        }

        SYST_CSR.* &= ~CSR_ENABLE;
        SYST_CVR.* = 0;
        remain -= chunk;
    }
}
