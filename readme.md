# car-zig

STM32F103 (Cortex-M3) 裸机 Zig 项目，基于 [microzig](https://github.com/ZigEmbeddedGroup/microzig) HAL。

## 项目简介

本项目是将一个 STM32F103 平衡小车的**裸机 C 固件**逐步移植为
**Zig + microzig** 的实践。目标是用 Zig 重写全部硬件驱动，验证其在裸机
嵌入式下的可用性与表达力。

- **驱动全部用 Zig 实现**（除 DMP 官方库直接编入，见下）。
- **每个驱动一个可运行的验证 app**（`apps/`），一个 app 编成一个独立固件。
- **驱动全部在真实硬件上验证过**（LED/OLED/按键/串口/IMU/电机/编码器/ADC/EXTI）。
- 踩过的坑记录在 [`docs/microzig-notes.md`](docs/microzig-notes.md) 与
  [`docs/troubleshooting.md`](docs/troubleshooting.md)。

### 已移植驱动

| 驱动 | 说明 |
|------|------|
| LED / delay / USART1 | GPIO、SysTick 延时、串口 |
| OLED (SSD1306) | 软件 SPI 128x64 |
| 按键 | 单击/双击/长按；另一版含 FIFO + 连发 |
| 软件 I2C + MPU6050 | 读 6 轴/温度 + data-ready 中断 |
| DMP | 混合编译官方 C 库，输出四元数/欧拉角 |
| ADC | 电池电压检测 |
| 电机 (TIM1 PWM) / 编码器 (TIM2/TIM4) | 电机驱动与测速 |
| EXTI / NVIC | 外部中断与优先级 |

> **为什么含 C？** MPU6050 的 DMP 是 5200 行官方 C，直接翻译不现实，
> 故用 `build.zig` 把其 C 源码**编入固件**，Zig 侧用 `export`/`extern` 桥接。
> 其余驱动均为纯 Zig。

## 硬件

- MCU: STM32F103C8 (64KB Flash / 20KB RAM)
- 板载 LED: **PA4**，推挽输出，高电平点亮
- 按键: **PA5**，上拉输入（按下为低）
- 串口: 板载 **CH340** 接 **USART1 (PA9/PA10)**，走板子 USB 口
- OLED: **SSD1306 128x64**，软件 SPI（RST=PB3, DC=PA15, SCL=PB5, SDA=PB4）
- MPU6050: 软件 I2C（**SCL=PB8, SDA=PB9**），7 位地址 0x68
- 电机: PWM **PA8 (TIM1_CH1) / PA11 (TIM1_CH4)**，方向 PB12~PB15
- 编码器: 左 **TIM2 (PA0/PA1)**，右 **TIM4 (PB6/PB7)**
- ADC: 电池电压 **PA6 (ADC1_IN6)**
- 调试/烧录: ST-Link (SWD) + OpenOCD

> **外设时钟**: microzig 的 `set_output_mode()` **不会自动开外设时钟**，
> 每个驱动初始化里都要手动使能 `RCC.APB2ENR`（曾导致 LED/OLED 全黑）。
> 详见 [`docs/microzig-notes.md`](docs/microzig-notes.md)。

## 结构

```
car-zig/
├── build.zig              # 构建定义（microzig MicroBuild + app 表格）
├── build.zig.zon          # 依赖声明
├── flake.nix              # 提供 Zig 0.17 + openocd + stlink
├── build.sh               # 仅构建（强制普通用户）
├── flash.sh               # 构建 + 烧录（仅 openocd 按需 sudo）
├── tools/
│   └── flash-retry.sh     # SWD 同步失败时反复重试烧录
├── docs/
│   ├── microzig-notes.md  # microzig 踩坑记录
│   └── troubleshooting.md # 环境/构建/烧录错误排查
├── modules/
│   └── drivers/           # 可复用驱动
│       ├── led.zig        # LED（句柄风格）
│       ├── delay.zig      # SysTick 阻塞延时
│       ├── usart.zig      # USART1（PA9/PA10）
│       ├── oled.zig       # SSD1306 + oled_font.zig
│       ├── nvic.zig       # NVIC 中断 + EXTI
│       ├── key.zig        # 按键扫描（单击/双击/长按，简易版）
│       ├── key_scan.zig   # 按键扫描 FIFO 版（含按下/弹起/长按/连发）
│       ├── i2c_soft.zig   # 软件模拟 I2C（SCL=PB8, SDA=PB9）
│       ├── mpu6050.zig    # MPU6050 寄存器层（加速度/陀螺仪/温度）
│       ├── adc.zig        # ADC 电池电压（PA6）
│       ├── motor.zig      # 电机 PWM（TIM1 PA8/PA11 + 方向 PB12~15）
│       ├── encoder.zig    # 编码器（TIM2/TIM4）
│       └── dmp.zig        # DMP（编译官方 C 库，输出四元数/欧拉角）
├── modules/dmp/           # DMP 官方 C 源码 + 平台适配头（混合编译）
├── apps/                  # 各应用（每个编成一个独立固件）
│   ├── led-blink/         # LED 闪烁（delay）
│   ├── blink-systick/     # LED 闪烁（SysTick）
│   ├── usart-echo/        # 串口发送
│   ├── oled-demo/         # OLED 显示
│   ├── irq-demo/          # 中断 + OLED 联动
│   ├── key-demo/          # 按键扫描（单击/双击/长按）
│   ├── key-fifo-demo/     # 按键 FIFO（按下/弹起/长按/连发）
│   ├── mpu6050-demo/      # MPU6050（软件 I2C 读原始数据）
│   ├── i2c-scan/          # I2C 总线诊断（扫描地址）
│   ├── adc-demo/          # ADC 电池电压
│   ├── encoder-demo/      # 电机 + 编码器联动
│   ├── encoder-test/      # 编码器独立测试（手转轮子）
│   ├── pin-read/          # PA12 引脚电平读取诊断
│   ├── exti-demo/         # EXTI + MPU6050 INT（data-ready 中断）
│   └── dmp-demo/          # DMP 四元数→欧拉角
└── .microzig-src/         # microzig 0.17.20 完整源码（path 依赖，见下）
```

### 驱动清单

| 驱动 | 对应参考工程 | 说明 |
|------|-------------|------|
| `led.zig` | `HARDWARE/LED` | `initBoardLed()` 返回句柄，`on/off/toggle/isOn` |
| `delay.zig` | `SYSTEM/delay` | `init(sysclk)` / `delayUs` / `delayMs`（SysTick 轮询）|
| `usart.zig` | `SYSTEM/usart` | `initUsart1(baud)`，`write/println/readByte` |
| `oled.zig` | `HARDWARE/OLED` | `initOled()`，`showString/Number/Char`、`refresh` |
| `nvic.zig` | `SYSTEM/sys`（中断部分）| `priorityGroupConfig` / `init` / `extiConfig` / `extiClearPending` |
| `key.zig` | `MiniBalance_HARDWARE/KEY` | `initBoardKey()`，`click/clickNDouble/longPress/keyScan` |
| `key_scan.zig` | `User/bsp/src/bsp_key.c` | `Scanner(n).init/scan/getKey`；按下/弹起/长按/连发 + FIFO |
| `i2c_soft.zig` | `HARDWARE/IIC/IOI2C.c` | `initBoardI2c()`；`start/stop/sendByte/readByte/writeRegs/readRegs` |
| `mpu6050.zig` | `HARDWARE/MPU6050` | 寄存器层：`init()`，`readMotion6/pushFiltered/readTemperature10x`，`enableDataReadyInt/setDataReadyRate100hz` |
| `adc.zig` | `HARDWARE/ADC` | `initBoardAdc()`；`readChannel/readBatteryRaw/batteryVoltMv` |
| `motor.zig` | `HARDWARE/MOTOR` | `initBoardMotor()`；`setA/setB/set/stop`（TIM1 PWM）|
| `encoder.zig` | `HARDWARE/ENCODER` | `initBoardEncoders()`；`left/right.read()`（脉冲数，带方向）|
| `dmp.zig` | `DMP`（混合编译）| `init()`；`readQuat/readEuler`（四元数→欧拉角）|

### 应用清单（各自独立固件）

| app | 验证内容 |
|-----|---------|
| `led-blink` | LED 闪烁（SysTick 延时）|
| `blink-systick` | LED 闪烁（同，独立示例）|
| `usart-echo` | USART1 发送（@115200）|
| `oled-demo` | OLED 显示文字 + 计数 |
| `irq-demo` | TIM3 中断计时 + 主循环刷新 OLED |
| `key-demo` | 按键单击/双击/长按识别 + OLED 计数显示 |
| `key-fifo-demo` | 按键 FIFO（TIM3 每 10ms 扫描）+ 按下/弹起/长按/连发 |
| `mpu6050-demo` | 软件 I2C 读 MPU6050（WHO_AM_I + 原始 6 轴 + 温度）|
| `i2c-scan` | I2C 总线地址扫描（诊断）|
| `adc-demo` | ADC 读电池电压（原始值 + mV）|
| `encoder-demo` | 电机小幅转动 + 编码器计数联动 |
| `encoder-test` | 编码器独立测试（手转轮子看计数）|
| `pin-read` | PA12 引脚电平读取诊断 |
| `exti-demo` | MPU6050 data-ready(100Hz) → PA12 下降沿 EXTI 计数 |
| `dmp-demo` | DMP 输出四元数→欧拉角（Roll/Pitch）|

`modules/` 放可复用驱动，`apps/` 放各应用；新增 app 时在 `build.zig` 的 `apps` 数组加一项。
每个 `apps/<name>` 编成**一个独立固件**（共用同一块 flash，一次只能跑一个）。

## 环境

Zig 0.17 尚未进入 nixpkgs（当前只有 0.16），故 `flake.nix` 直接拉取官方预编译包。

```sh
nix develop .#        # 进入开发环境（zig 0.17 / openocd / stlink）
```

> **代理**：Zig 0.17 不认 `socks://`，需 `socks5://`。
> `build.sh` / `flash.sh` 已自动修正；手动调用时设
> `ALL_PROXY=socks5://127.0.0.1:7897`。

## 构建与烧录

**构建与烧录分离**：构建必须普通用户（避免污染 `.zig-cache` 属主）。

```sh
./build.sh                  # 构建（产物在 zig-out/firmware/）
./build.sh led-blink        # 只构建指定 app

./flash.sh                  # 构建 + 烧录
./flash.sh --no-build       # 跳过构建，只烧录
```

**SWD 连不上时**（OpenOCD 报 `init mode failed (unable to connect to the target)`），
用 `tools/flash-retry.sh` 反复重试，运行期间**反复轻按板子 RESET 键**抢连接：

```sh
./build.sh key-demo             # 先构建
./tools/flash-retry.sh key-demo # 重试烧录（默认 30 次）
./tools/flash-retry.sh key-demo 100  # 增大重试次数
```

脚本会自动处理 ST-Link 权限：无权限时仅对 openocd 一步 `sudo`。
要彻底免 sudo，把当前用户加入 `plugdev` 组（并让 udev 规则生效）。

直接使用 zig：

```sh
zig build                  # 构建全部 app
zig build led-blink        # 构建指定 app
zig build -l               # 列出所有 step
zig build flash-led-blink  # 构建并烧录
```

## 关于 .microzig-src

`.microzig-src/` 是 microzig 0.17.20 的**完整源码副本**，通过 path 依赖引用。

**为什么不用 `git+https://...` 直接拉取？**
microzig 的 `build.zig.zon` 里 `.paths` 只列了少数文件，却引用了 `port/`、`core/` 等
未列出的目录。zig 从 git 拉取时只取 `.paths` 内的文件，导致构建报
`dependency 'port/stmicro/stm32' does not have a build.zig`。
（这是 microzig 上游的问题，非本项目。）

**重建 `.microzig-src`**（若被误删）：

```sh
nix flake prefetch github:ZigEmbeddedGroup/microzig/0.17.20
# 从输出的 storePath 拷贝
cp -rL /nix/store/<...>-source .microzig-src
chmod -R u+w .microzig-src
```

> 上游修复后，可改回 `.url` + `.hash` 形式，届时 `.microzig-src` 可删除并忽略。

## 驱动风格

`modules/drivers/led.zig` 采用 **Zig 句柄风格**（对照 C 工程 `bsp_led.c` 的职责划分）：

```zig
const led = @import("led");

const my_led = led.initBoardLed();   // 配置引脚，拿到句柄
my_led.on();
my_led.toggle();
my_led.isOn();
```

- 无全局可变状态：句柄由调用方持有
- 零成本抽象：Release 构建下方法被完全内联

## 文档

- [`docs/microzig-notes.md`](docs/microzig-notes.md)：microzig 踩坑（外设时钟/TIM/编码器等）
- [`docs/troubleshooting.md`](docs/troubleshooting.md)：环境/构建/烧录错误排查

## 许可

本项目采用 [MIT License](LICENSE)。

`modules/dmp/` 下的 `inv_mpu*.c/.h`、`dmpKey.h`、`dmpmap.h` 为第三方源码，
版权归原作者（见文件内的 license 头），随本项目一并分发。
