//! 本模块对照其接口，底层用 microzig 的 `microzig.interrupt` +
//! 直接操作 SCB->AIRCR（microzig 未直接暴露优先级分组）。
//!
//! 优先级分组（AIRCR.PRIGROUP = 7-group）:
//!   组0: 0 位抢占, 4 位响应
//!   组1: 1 位抢占, 3 位响应
//!   组2: 2 位抢占, 2 位响应    ← 参考工程 main() 用 MY_NVIC_PriorityGroupConfig(2)
//!   组3: 3 位抢占, 1 位响应
//!   组4: 4 位抢占, 0 位响应
//! 数值越小优先级越高。

const std = @import("std");
const microzig = @import("microzig");

/// SCB->AIRCR 地址（Cortex-M3）。
const SCB_AIRCR: *volatile u32 = @ptrFromInt(0xE000ED0C);

/// AIRCR 写入钥匙（高 16 位必须为 0x05FA，否则写入无效）。
const AIRCR_VECTKEY: u32 = 0x05FA_0000;

/// 中断优先级分组（0~4），对应参考工程 NVIC_Group。
pub const Group = enum(u3) {
    g0 = 0, // 0 位抢占, 4 位响应
    g1 = 1,
    g2 = 2, // 参考工程 main 用这个
    g3 = 3,
    g4 = 4, // 4 位抢占, 0 位响应
};

/// 对照 MY_NVIC_PriorityGroupConfig()：设置 NVIC 优先级分组。
pub fn priorityGroupConfig(group: Group) void {
    // PRIGROUP 字段在 bit[10:8]，写入值 = 7 - group
    const prigroup: u32 = 7 - @as(u32, @intFromEnum(group));
    var temp = SCB_AIRCR.*;
    temp &= 0x0000_F8FF; // 清 PRIGROUP[10:8]
    temp |= AIRCR_VECTKEY; // 写入钥匙
    temp |= (prigroup & 0x7) << 8;
    SCB_AIRCR.* = temp;
}

/// 中断优先级值（抢占/响应合并后的 4 位，数值越小越优先）。
/// 参考工程 set_priority 时取 `pre << (4-group) | (sub & (0x0F >> group))`。
pub const Priority = microzig.cpu.interrupt.Priority;

/// 对照 MY_NVIC_Init()：设置某中断的优先级并使能。
///
/// `preemption` 抢占优先级, `sub` 响应优先级, `int` 中断号, `group` 分组。
/// 底层用 microzig 的 set_priority + enable。
pub fn init(
    comptime preemption: u4,
    comptime sub: u4,
    comptime int: microzig.cpu.ExternalInterrupt,
    comptime group: Group,
) void {
    const g: u4 = @intFromEnum(group);
    // 与参考工程一致: temp = pre << (4-group) | (sub & (0x0F >> group))
    const pre_shifted: u4 = if (4 - @as(u3, g) >= 4) 0 else preemption << @intCast(4 - @as(u3, g));
    const sub_masked: u4 = sub & (@as(u4, 0x0F) >> @intCast(g));
    const prio: u4 = (pre_shifted | sub_masked) & 0x0F;

    microzig.cpu.interrupt.set_priority(int, @enumFromInt(prio));
    microzig.cpu.interrupt.enable(int);
}

/// 使能全局中断（对照参考工程的 __enable_irq）。
pub fn enableInterrupts() void {
    microzig.cpu.interrupt.enable_interrupts();
}

/// 关闭全局中断。
pub fn disableInterrupts() void {
    microzig.cpu.interrupt.disable_interrupts();
}

/// 单独使能/禁用某个中断。
pub fn enable(comptime int: microzig.cpu.ExternalInterrupt) void {
    microzig.cpu.interrupt.enable(int);
}

pub fn disable(comptime int: microzig.cpu.ExternalInterrupt) void {
    microzig.cpu.interrupt.disable(int);
}

// ---------- 外部中断 (EXTI) —— 对照 Ex_NVIC_Config ----------

/// 触发沿（对应参考工程 TRIM 参数）。
pub const Trigger = enum {
    falling, // FTIR (TRIM&0x01)
    rising, // RTIR (TRIM&0x02)
    both, // 下降+上升
};

/// 对照 Ex_NVIC_Config(GPIOx, BITx, TRIM): 配置一个 GPIO 的外部中断。
///
/// `port` GPIOA..G, `line` 引脚号 0~15, `trigger` 触发沿。
/// 会自动使能 AFIO 时钟、映射 EXTI 线、使能中断、设触发沿。
/// 注意: 还需要另行调用 `init()` 在 NVIC 里使能对应的 EXTIx 中断。
pub fn extiConfig(comptime port: microzig.hal.gpio.Port, comptime line: u4, trigger: Trigger) void {
    const exti = microzig.hal.exti;

    // 使能 AFIO 时钟（对照 RCC->APB2ENR |= 0x01）
    microzig.chip.peripherals.RCC.APB2ENR.modify_one("AFIOEN", 1);

    const edge: exti.TriggerEdge = switch (trigger) {
        .falling => .falling,
        .rising => .rising,
        .both => .both,
    };

    exti.apply_line(.{
        .line = line,
        .port = port,
        .trigger = edge,
        .interrupt = true, // 使能 line 上的中断
    });
}

/// 清某条 EXTI 线的 pending 标志（中断处理函数里调用）。
/// 对照参考工程在 ISR 里 `EXTI_ClearITPendingBit(EXTI_LineX)`。
pub fn extiClearPending(comptime line: u4) void {
    const EXTI = microzig.chip.peripherals.EXTI;
    EXTI.@"PR[0]".raw |= (@as(u32, 1) << line);
}

/// 读某条 EXTI 线的 pending 标志（是否触发）。
pub fn extiPending(comptime line: u4) bool {
    const EXTI = microzig.chip.peripherals.EXTI;
    return (EXTI.@"PR[0]".raw & (@as(u32, 1) << line)) != 0;
}
