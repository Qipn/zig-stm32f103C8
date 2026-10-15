# microzig 踩坑记录

本文记录将平衡小车的 STM32F103 裸机 C 工程移植到
**Zig + microzig 0.17.20** 过程中遇到的关键问题。每条都给出了现象、根因与解法。

这些坑的共同特点：**C 工程里寄存器写得很"直白"**，而 microzig 面向多芯片做了抽象，
抽象层与实际芯片的默认状态之间存在缺口，若不清楚就会踩到。

---

## 坑 1：`set_output_mode()` 不自动开外设时钟

### 现象

调用 microzig 的 `pin.set_output_mode(...)` 配置好 GPIO，但：

- LED 全黑，不亮
- OLED 全黑，无任何显示
- 而代码逻辑、时序、接线都检查无误

### 根因

microzig 的 `gpio.Pin.set_output_mode()` 只写 **GPIOx_CRL/CRH** 寄存器，
**不会**去使能对应 GPIO 端口在 `RCC->APB2ENR` 里的时钟位。

STM32 复位后所有外设时钟默认是**关闭**的。时钟关闭时，对 GPIO 寄存器的写入会被
硬件静默忽略（不报错），于是配置看似"成功"，实则没生效。

对照 C 工程，这一步是显式做的：

```c
RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);
```

### 解法

在每个驱动的初始化里，手动使能引脚所在端口的时钟。例：`modules/drivers/led.zig`

```zig
const RCC = microzig.chip.peripherals.RCC;

pub fn init(self: Led) Led {
    // APB2ENR 里 GPIOA..G 对应 bit2..bit8
    const port_index: u5 = @intCast(@backingInt(self.pin) / 16);
    const bit: u32 = @as(u32, 1) << (port_index + 2);
    RCC.APB2ENR.raw |= bit;
    _ = RCC.APB2ENR.raw & bit; // 读回，确保写入生效

    self.pin.set_output_mode(.general_purpose_push_pull, .max_50MHz);
    self.off();
    return self;
}
```

也可以使用 microzig 的封装：`hal.rcc.enable_clock(.GPIOA)`（`usart.zig` 就是这么做的）。
**关键是别忘。**

> 端口 → APB2ENR 位映射：GPIOA..GPIOG = bit 2..8，AFIO = bit 0。

---

## 坑 2：`rcc.get_clock()` 返回编译期假定时钟

### 现象

- 串口输出乱码，或完全无输出
- 用 `rcc.get_clock()` 得到的频率去算 USART 的 `BRR`（波特率分频），结果与实际不符

### 根因

本项目**从未调用 `rcc.apply()`**，芯片一直跑在**复位默认的 HSI 8MHz**（未开 PLL）。

而 microzig 的 `rcc.get_clock()` 返回的是**编译期由配置推导出的假定值**，
并不是运行时从寄存器读出的真实时钟。二者不一致时，所有依赖时钟的外设
（串口、定时器…）分频都会算错。

### 解法（实测反推）

本项目通过实测确定真实时钟。观察 USART1 的 `BRR`：

```
BRR = 0xd0            // mantissa = 13
PCLK2 = 38400 × 16 × 13 = 8_000_000   // 8MHz
```

即在 8MHz 下 `BRR = 8e6 / (16 × baud)`，与复位 HSI 8MHz 完全吻合。

因此 `modules/drivers/usart.zig` 显式传入实际外设时钟，不再依赖 `get_clock()`：

```zig
pub const default_pclk2: u32 = 8_000_000;

pub fn initUsart1WithClock(baud_rate: u32, pclk2: u32) Usart { ... }
pub fn initUsart1(baud_rate: u32) Usart {
    return initUsart1WithClock(baud_rate, default_pclk2);
}
```

> **后续若配置 PLL 改变系统时钟，务必同步修改 `default_pclk2` 及 `delay.init()` 的入参。**

---

## 坑 3：`hal.time.sleep_ms` 依赖 time 子系统

### 现象

主循环里调用 `hal.time.sleep_ms(...)` 后程序卡死，不再往后执行。

### 根因

microzig 的 `hal.time` 是一套**基于定时器中断的 time 子系统**，
需要先初始化定时器（如 `time.init_timer(...)`），且其内部对时钟的假定要与实际一致
（正好也是**坑 2** 的受害者）。

若未初始化就直接 sleep，会卡在等待永远不会到来的 tick 上。

### 解法：改用 SysTick 轮询延时

Cortex-M 内核自带 **SysTick**（地址固定 `0xE000E010`），用法简单可靠：

- 是**内核外设**，不需要开任何 `RCC` 时钟
- 用**轮询 COUNTFLAG**，不依赖中断、不依赖 microzig 时钟模型

`modules/drivers/delay.zig` 即照此实现（对照参考工程 `SYSTEM/delay/delay.c` 非 OS 版）：

```zig
const SYST_CSR: *volatile u32 = @ptrFromInt(0xE000E010);
const SYST_RVR: *volatile u32 = @ptrFromInt(0xE000E014);
const SYST_CVR: *volatile u32 = @ptrFromInt(0xE000E018);

pub fn init(system_clock: u32) void {
    SYST_CSR.* &= ~(1 << 2);          // CLKSOURCE = 0 → HCLK/8
    fac_us = system_clock / 8_000_000; // 每 us 的节拍数
    if (fac_us == 0) fac_us = 1;
}

pub fn delayUs(nus: u32) void {
    SYST_RVR.* = (nus * fac_us) & 0x00FFFFFF;
    SYST_CVR.* = 0;
    SYST_CSR.* |= 1;                  // 启动
    while ((SYST_CSR.* & (1 << 16)) == 0) {} // 等 COUNTFLAG
    SYST_CSR.* &= ~@as(u32, 1);
    SYST_CVR.* = 0;
}
```

**使用前提**：`delay.init(实际系统时钟)` 传入真实频率（见坑 2）。

---

## 坑 4：TIM2 被 `hal.time` 子系统占用

### 现象

用 TIM2 做中断计时（移植参考工程的定时器中断），一使能中断就进 **HardFault**。

### 根因

**microzig 的 `hal.time` 子系统默认占用 TIM2** 作为它的时基定时器。
自己再去配置/使用 TIM2 的中断，会与 microzig 内部配置**冲突**，导致异常。

### 解法

换一个**未被 microzig 占用**的定时器。本项目 `irq-demo` 改用 **TIM3**
（`hal.time` 不占用它）：

```zig
// 用 TIM3 而非 TIM2，避免与 microzig 的 time 子系统冲突
// 1. 使能 TIM3 时钟 (APB1ENR)
// 2. 配置 PSC / ARR 得到所需中断周期
// 3. 开 UIE，并在 NVIC 里使能 TIM3_IRQn
// 4. 在 interrupt 处理函数里清更新标志 SR.UIF
```

---

## 坑 5：双向引脚两端都要配成输出（I2C 的 SCL）

### 现象

软件 I2C 读 MPU6050 一直 `READ ERR`；总线扫描（`i2c-scan`）也扫不到任何地址。

### 根因

参考工程 `IIC_Init()` 把 **SCL 和 SDA 一起**配成推挽输出：

```c
GPIO_InitStructure.GPIO_Pin = GPIO_Pin_8|GPIO_Pin_9;  // SCL | SDA
GPIO_InitStructure.GPIO_Mode = GPIO_Mode_Out_PP;
```

而移植时**只配了 SDA（输出）、漏了 SCL**。STM32 复位后 GPIO 默认是**输入态**，
对未配成输出的 SCL 写 ODR **完全无效** → SCL 永远不变电平 → 总线上没有时钟脉冲
→ 从机不 ACK → 读什么都失败。

### 解法

`i2c_soft.zig` 的 `init()` 里**两根线都设成输出**：

```zig
self.sdaOut(); // SDA 推挽输出
self.scl.set_output_mode(.general_purpose_push_pull, .max_50MHz); // SCL 也要！
```

> 通用教训: 任何“要驱动电平”的引脚（I2C/SPI 软件模拟、SPI、并口…）
> 都必须 **先 set_output_mode 再 put**。复位默认输入态，漏配就变成“写了没反应”。

---

## 坑 6：microzig 不支持高级定时器 TIM1（含 BDTR.MOE）

### 现象

电机 PWM 用 TIM1，但 microzig 的 timer HAL 无法配置它。

### 根因

microzig 的 timer HAL（`timer_v1.zig`）里 `Instances = enums.TIMGP16_Type`，
**只包含通用定时器 TIM2~5（`TIM_GP16`）**，而 TIM1 是高级定时器（`TIM_ADV`），
**不在其中**。

### 解法：直接写 TIM1 寄存器

与参考工程一致，直接操作 `microzig.chip.peripherals.TIM1`（见 `motor.zig`）：

- `PSC` / `ARR`：时基
- `CCMR_Input[0/1].raw`：设 OCxM=110 (PWM1) + OCxPE（见坑 8 字段名陷阱）
- `CCER`：使能 CCxE（输出）
- **`BDTR.MOE=1`**：高级定时器**必须**使能主输出，否则引脚无 PWM（最易忘）
- `CR1.CEN=1`：启动

---

## 坑 7：编码器模式不要使能 CCxE

### 现象

编码器计数异常/不动。

### 根因

编码器接口模式下，输入通道的 `CCxS=01`（映射自 TI1/TI2）即可，
**不应**使能 `CCxE`（capture/compare 输出使能）。对照 SPL 的
`TIM_EncoderInterfaceConfig`：它**只设极性位（CCxP），不动 CCxE**。
最初错写成 `CCER = (1<<0)|(1<<4)`（使能了 CC1E/CC2E），反而干扰计数。

### 解法

```zig
regs.SMCR.raw = 0b011; // SMS=011 编码器模式3（TI12）
regs.CCMR_Input[0].raw = 0b01 | (0b01 << 8) | (10 << 4) | (10 << 12); // CC1S/CC2S=01, 滤波=10
regs.CCER.raw = 0;     // 不使能 CCxE（上升沿 = 极性 0）
```

---

## 坑 8：microzig 寄存器字段名与参考手册不一致

### 现象

写 `TIM1.CCMR1_Output.raw = ...` 报 `no field named 'CCMR1_Output'`。

### 根因

microzig 的自动生成寄存器类型里，TIM_ADV 只声明了 `CCMR_Input: [2]Mmio(...)`，
**没有** `CCMR1_Output` / `CCMR2_Output` 字段（虽然手册里是同一对寄存器）。

### 解法

用输入模式的别名写 `.raw`（底层地址就是 CCMR1/CCMR2，写值不受字段名影响）：

```zig
TIM1.CCMR_Input[0].raw = (0b110 << 4) | (1 << 3);   // CCMR1: OC1M=110, OC1PE=1
TIM1.CCMR_Input[1].raw = (0b110 << 12) | (1 << 11); // CCMR2: OC4M=110, OC4PE=1
```

> 看寄存器字段名前，先查 `.zig-cache/**/chips/types/peripherals/*.zig` 的实际声明。

---

## 摆脱 `hal.time`：OLED 改用 SysTick

因为参考工程编码器要用 **TIM2**，而 TIM2 被 `hal.time` 占用（坑 4），
所以把 **OLED 驱动里的 `hal.time.sleep_ms(100)` 改为 `delay.delayMs(100)`**，
并移除所有 app 里的 `hal.time.init_timer(.TIM2)`。

结果: 全项目不再用 `hal.time`，**TIM2 腾出来给左轮编码器**。

> 教训: 能用自足的 SysTick 就尽量不用 `hal.time`，少一层时钟假设、少占一个定时器。

---

## 速查表

| # | 坑 | 一句话解法 |
|---|----|-----------|
| 1 | `set_output_mode` 不开外设时钟 | 初始化里手动 `RCC.APB2ENR |= ...` 或用 `hal.rcc.enable_clock()` |
| 2 | `rcc.get_clock()` 是编译期假定值 | 实测反推真实时钟，显式传入（本项目 8MHz）|
| 3 | `hal.time.sleep_ms` 未初始化会卡死 | 改用 SysTick 轮询延时（`delay.zig`）|
| 4 | TIM2 被 `hal.time` 占用 | 换用 TIM3，或让驱动完全不用 `hal.time`（见下）|
| 5 | 双向引脚两端都要配输出 | I2C 的 **SCL 也需配成输出**，否则总线不动（见下）|
| 6 | 高级定时器 microzig 不支持 | TIM1 直接写寄存器，别忘 `BDTR.MOE` |
| 7 | 编码器模式 CCER 不要使能 CCxE | `CCER=0`（只设极性），否则干扰计数 |
| 8 | microzig 寄存器字段名与手册不一致 | 如 TIM_ADV 只有 `CCMR_Input[]`，写输出模式用 `.raw` |
| 9 | MPU INT 默认无信号 | 要配 `INT_ENABLE` 的 data-ready 才输出 |
| 10 | MPU INT 悬空需拉高 | INT 用推挽输出（`INT_OPEN=0`），或 STM32 侧上拉 |

---

## 驱动分层：软件 I2C 与 MPU6050 分离

`i2c_soft.zig`（总线）与 `mpu6050.zig`（器件）是**两层**，不要混在一起：

- `i2c_soft.zig` 只做 GPIO 时序，任何 I2C 器件都可用；
- `mpu6050.zig` 只管 MPU6050 寄存器，通过参数接收任意 I2C 后端。

**SDA 是双向线**：发送前 `set_output_mode`，接收前 `set_input_mode(.pull)`，
与参考工程 `SDA_IN()/SDA_OUT()` 对应。

### 跨驱动依赖：build.zig 的模块导入

microzig 的 import 绑定到 firmware，**驱动模块之间默认看不到彼此**
（直接 `@import("i2c_soft")` 会报 `no module named 'i2c_soft'`）。

解法：`build.zig` 的驱动项现在支持 `.deps`（它 import 哪些其它驱动），
先建好全部 module 再加 `mod.addImport(...)`：

```zig
.{ .name = "i2c_soft", .path = Drivers.i2c_soft, .deps = &.{"delay"} },
.{ .name = "mpu6050", .path = Drivers.mpu6050, .deps = &.{"i2c_soft"} },
```

---

## MPU6050 / DMP

参考工程的 MPU6050 分两层：

1. **寄存器层**（`mpu6050.zig`）：读原始 6 轴 / 温度。
2. **DMP 层**（`dmp.zig` + `modules/dmp/`）：靠 DMP 固件输出四元数。

### DMP：混合编译（不翻译 C）

DMP 是 5200 行 C（`inv_mpu.c` + `inv_mpu_dmp_motion_driver.c`），**不翻译**，
而是用 `build.zig` 的 `fw.exe.root_module.addCSourceFile` **直接编入固件**，
Zig 侧通过 `export`/`extern` 桥接。踩过的坑:

1. **替代平台头**：原码靠 `sys.h` 拉全部外设头；用最小的 `dmp_port.h` 替代。
2. **无 libc 头**：freestanding 下不能 include `<string.h>` 等，改为**手工声明**
   `memset/memcpy/memcmp/labs/fabsf`（实现来自 compiler-rt 或自写）。
3. **展开表狂占 flash**：默认 C 会生成 `.ARM.exidx/.extab`，占上百 KB。
   必须加 `-ffreestanding -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-builtin`。
4. **debug 超容量**：即使加了 flags，debug 下仍超 64KB flash → 给该 app
   单独设 `optimize = ReleaseSmall`（`build.zig` 的 `optimize_override`）。
5. **microzig 的 `fw.add_c_source_file` 在 Zig 0.17 失效**（`fw.exe.addCSourceFile`
   已移除）→ 改用 `fw.exe.root_module.addCSourceFile`。
6. **缺符号**（`labs`/`memcmp`）→ 在 Zig 里 `export` 补齐。

平台函数（C 上钩）在 `dmp.zig` 里以 C ABI 导出，转调 `i2c_soft`/`delay`：

```zig
export fn i2c_write(addr: u8, reg: u8, len: u8, data: [*]const u8) callconv(.c) c_int { ... }
export fn i2c_read (addr: u8, reg: u8, len: u8, data: [*]u8)        callconv(.c) c_int { ... }
```

> 若以后不用 DMP，可改用互补滤波/卡尔曼（参考工程 `KF/` `filter/`）自己算，
> 纯 Zig 更干净。

---

## 两种按键算法

本项目有两个按键驱动，对应两份不同参考工程：

| 驱动 | 参考 | 特点 |
|------|------|------|
| `key.zig` | `KEY/key.c` | 单击/双击/长按；非阻塞周期调用；状态存句柄 |
| `key_scan.zig` | `bsp_key.c` | 按下/弹起/长按/**连发** + **FIFO**；推荐 |

**`key_scan.zig` 的关键点（值得借鉴的工程细节）**：

- **消抖计数器** `Count`：从 0→`KEY_FILTER_TIME`(5) 再→2×，需连续 50ms 稳定才认定
  按下/弹起，硬件无滤波也能可靠。
- **单键互斥**：单键事件要求“全局只有一个键被按下”，防组合键误触发。
- **扫描与消费分离**：`scan()` 在定时中断（10ms）里跑，事件入 FIFO；
  主循环 `getKey()` 取 —— 解耦了扫描时序与业务处理耗时。
- **连发**：长按到 `LongTime` 后，每 `RepeatSpeed` 个 tick 重发一次 DOWN。

本项目的 `key-fifo-demo` 用 TIM3 每 10ms 中断调 `scan()`（对照参考工程由
systick 调 `bsp_KeyScan10ms()`）；主循环抽 FIFO 刷新 OLED。
定时器选择注意避开 `hal.time` 占用的 TIM2（见坑 4）。

---

## 补充：上拉/下拉输入要两步

配置上拉输入时，`pin.set_input_mode(.pull)` **只设 CNF/MODE**，还需
`pin.set_pull(.up)` 写 ODR 才能选中"上拉"（否则是下拉）。
`key.zig` 的 `init()` 即两步都做：

```zig
self.pin.set_input_mode(.pull); // CNF=10, MODE=00
self.pin.set_pull(.up);         // ODR=1 → 上拉（对应 GPIO_Mode_IPU）
```

---

## 硬件事实备忘（STM32F103C8）

- 系统时钟实际运行：**HSI 8MHz**（无 PLL，复位默认）
- LED：**PA4**，高电平点亮
- 按键：**PA5**，上拉输入（按下为低），与 LED/OLED 引脚不冲突
- USART1：**PA9=TX / PA10=RX**，接板载 CH340
- OLED SSD1306：软件 SPI（RST=PB3, DC=PA15, SCL=PB5, SDA=PB4）
- MPU6050：**软件 I2C：SCL=PB8, SDA=PB9**，7 位地址 0x68（AD0 接地）
- 电机：PWM **PA8 (TIM1_CH1) / PA11 (TIM1_CH4)**，方向 AIN1=PB14/AIN2=PB15/BIN1=PB13/BIN2=PB12
- 编码器：左 **TIM2 (PA0/PA1)**，右 **TIM4 (PB6/PB7)**，浮空输入
- ADC 电池：**PA6 (ADC1_IN6)**，分压比约 1/11
- EXTI：**PA12 = MPU6050 INT**，下降沿中断（EXTI15_10）
- PB3/PB4/PA15 默认是 JTAG 复用脚，作 GPIO 前需 `disableJtagKeepSwd()` 切到仅 SWD

---

## EXTI + MPU6050 INT（data-ready 中断）

### 现象

PA12（= MPU6050 INT）接上 EXTI，但用杜邦线碰 GND 也**不计数**；量 PA12 恒为**低电平**。

### 根因

1. **MPU6050 的 INT 引脚默认不输出任何信号** —— 它是可编程中断输出，
   必须配置 `INT_ENABLE`（使能具体中断源）才会动。
2. 本板 **INT 脚悬空、无外部上拉**。开漏输出拉不高 → 需在 STM32 侧上拉，
   或让 MPU6050 用**推挽输出**。
3. 下降沿中断需要“高→低”跳变；若引脚恒低，就永远没边沿。

### 解法

`mpu6050.zig` 提供：

```zig
mpu.setDataReadyRate100hz();                 // 采样率 100Hz
mpu.enableDataReadyInt(true, true, false);   // 推挽, 低有效, 脉冲
```

- `INT_PIN_CFG(0x37)`: `INT_OPEN=0`（**推挽**，不依赖外部上拉）、`INT_LEVEL=1`（低有效）。
- `INT_ENABLE(0x38)`: `DATA_RDY_EN=1`（每采样一帧数据输出一个脉冲）。
- **采样率决定中断频率**: `采样率 = 陀螺输出率 / (1 + SMPLRT_DIV)`。
  DLPF 开启时陀螺输出 1kHz，要 100Hz（=10ms）→ `SMPLRT_DIV=9`。

验证: `apps/exti-demo` 的 irq 计数约每 10ms +1。

> **中断与轮询会抢 pending**：若同时使能中断与主循环轮询 `PR`，
> 中断会抢先清掉标志，轮询读到 0。二选一即可（实测中断优先）。

---

## 烧录：SWD 连不上时的处理

OpenOCD 报 `init mode failed (unable to connect to the target)` 是常见现象
（ST-Link 没抢到 SWD 同步）。解法：

- 用 `tools/flash-retry.sh <app>` 反复重试，**运行期间反复轻按板子 RESET 键**。
- 彻底卡死时全片擦除救援：
  ```sh
  sudo st-flash --connect-under-reset erase
  arm-none-eabi-objcopy -O binary zig-out/firmware/<app>.elf /tmp/x.bin
  sudo st-flash --connect-under-reset write /tmp/x.bin 0x08000000
  ```
