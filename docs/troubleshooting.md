# 常见错误与排查

本项目从**工具链/环境 → 构建 → 烧录 → 运行时**各环节踩过的错误汇总。
每类是：**现象 → 根因 → 解决办法**。

> 详细的外设驱动类问题（时钟/TIM/编码器等）见 [`microzig-notes.md`](microzig-notes.md)。

---

## 一、环境与工具链

### 1. `zig` 版本过旧（nixpkgs 只有 0.16）

**现象**: `nix develop` 后 `zig version` 是 0.16，编不过本项目（需 0.17）。

**根因**: Zig 0.17 尚未进入 nixpkgs。

**解决**: `flake.nix` 直接拉官方预编译包，不依赖 nixpkgs 的 zig。

### 2. Zig 下载失败：`HttpConnectionClosing`

**现象**: 拉依赖时报 `HttpConnectionClosing`。

**根因**: Zig 0.17 **不认 `socks://`** 代理协议，必须 `socks5://`。

**解决**: `build.sh`/`flash.sh` 已自动把 `socks://` 改写为 `socks5://`。
手动调用时设 `ALL_PROXY=socks5://127.0.0.1:7897`。

### 3. 构建报 `dependency 'port/stmicro/stm32' does not have a build.zig`

**现象**: 用 `git+https://...` 拉 microzig 时构建失败。

**根因**: microzig 的 `build.zig.zon` 里 `.paths` 只列了少数文件，却引用了
`port/`、`core/` 等未列出的目录。Zig 从 git 拉取时只取 `.paths` 内文件。

**解决**: 用**完整源码副本** `.microzig-src/`（path 依赖）。见 readme。

### 4. 构建报 `.zig-cache` 权限错误

**现象**: `error: unable to open ... .zig-cache/...: Permission denied`。

**根因**: 之前用 `sudo` 跑过构建，`.zig-cache` 属主变成 root。

**解决**: **绝不用 sudo 构建**（`build.sh` 会拦截）。
若已污染: `sudo chown -R $(id -u):$(id -g) .zig-cache`.

---

## 二、编译错误（Zig 语法/API）

### 5. `binary operator '*' has whitespace on one side`

**现象**: `[_]T{.{}} ** n` 之类的数组重复语法报错。

**根因**: Zig 0.17 对 `**` 运算符要求**两侧都有空格**。

**解决**: 避免裸用 `**`；用 comptime 函数或 `@splat` 生成数组，例如:

```zig
fn defaultBtnStates(comptime n: usize) [n]ButtonState {
    var a: [n]ButtonState = undefined;
    for (&a) |*b| b.* = .{};
    return a;
}
```

### 6. `division with 'i16' ... signed integers must use @divTrunc`

**根因**: Zig 不允许对**有符号整数**用 `/`，必须显式 `@divTrunc/@divFloor/@divCeil/@divExact`。

**解决**: `@divTrunc(a, b)`。

### 7. `no field named 'CCMR1_Output' in ... TIM_ADV`

**根因**: microzig 自动生成的寄存器类型里，TIM_ADV 只声明了 `CCMR_Input: [2]`，
没有输出模式别名。

**解决**: 写输出模式时用 `CCMR_Input[i].raw`（底层地址相同）。见 microzig-notes 坑 8。

---

## 三、链接错误（容量/符号）

### 8. `section '.text' will not fit in region 'BANK_1'`（几万~几十万字节）

**现象**: 编入 C 源文件（如 DMP 库）后链接失败，超 flash 容量。

**根因**: 裸机 C 默认生成**异常展开表**（`.ARM.exidx`/`.ARM.extab`），占上百 KB；
且 `debug` 模式不做尺寸优化。

**解决**:
1. C 编译加 flags: `-ffreestanding -fno-unwind-tables
   -fno-asynchronous-unwind-tables -fno-builtin -Os`
2. 该 app 用 `ReleaseSmall`（本项目给 `dmp-demo` 设了 per-app `optimize_override`）。

### 9. `undefined symbol: labs` / `memcmp`

**根因**: freestanding 无 libc，这些函数没实现（`memset/memcpy` 由 compiler-rt 提供，
但 `labs/memcmp` 不保证）。

**解决**: 在 Zig 里 `export` 补齐:

```zig
export fn labs(x: c_long) callconv(.c) c_long { return if (x < 0) -x else x; }
```

### 10. `microzig 的 add_c_source_file/add_include_path 失效`

**现象**: 报 `no field or member function named 'addIncludePath' in 'Build.Step.Compile'`。

**根因**: microzig 的 `fw.exe.addCSourceFile()` 在 Zig 0.17 已移除。

**解决**: 用 `fw.exe.root_module.addCSourceFile(...)` / `.addIncludePath(...)`。

---

## 四、烧录

### 11. `init mode failed (unable to connect to the target)`

**现象**: OpenOCD 连不上目标，SWD 同步失败（间歇性，常发生）。

**解决**:
- 用 `tools/flash-retry.sh <app>` 反复重试；
- 运行期间**反复轻按板子 RESET 键**抢连接（最有效）；
- 脚本默认用**低速模式**（`adapter speed 100` + `connect_assert_srst`）提升成功率。

### 12. 脚本"成功了还在重试"

**现象**: 已 `Programming Finished` + `Verified OK`，脚本却继续重试。

**根因**: 间歇性 SWD 下，固件已烧录成功，但最后的 `reset`/`shutdown` 又掉线，
导致 **openocd 退出码非 0**。

**解决**: 判断成功**看日志里的 `Verified OK`**，不看退出码（脚本已这样改）。

### 13. 芯片卡死救援

**现象**: 芯片进了 HardFault，SWD 完全连不上。

**解决**: 全片擦除后重烧:

```sh
sudo st-flash --connect-under-reset erase
arm-none-eabi-objcopy -O binary zig-out/firmware/<app>.elf /tmp/x.bin
sudo st-flash --connect-under-reset write /tmp/x.bin 0x08000000
```

### 14. `cd: not in any of the project's worktrees`

**现象**: 工具里 `cd car-zig` 报错。

**根因**: 工作目录必须是**项目根目录之一**（本项目根是 `stm32`）。

**解决**: `cd` 填 `stm32`，目录切换写在 `command` 里。

---

## 五、运行时（黑屏/无响应/读不到）

> 这几条是**驱动移植**问题，详见 [`microzig-notes.md`](microzig-notes.md)，
> 这里只列速查。

| 现象 | 根因 | 速查 |
|------|------|------|
| LED/OLED 全黑 | `set_output_mode` 不开外设时钟 | 手动 `RCC.APB2ENR |= ...` |
| 串口乱码 | `rcc.get_clock()` 是编译期假定值 | 显式传实际时钟（8MHz）|
| 程序卡死 | `hal.time.sleep_ms` 未初始化 | 改用 SysTick 延时 |
| TIM2 中断 HardFault | TIM2 被 `hal.time` 占用 | 换 TIM3，或不用 `hal.time` |
| I2C 读不到 | **SCL 未配成输出** | 两线都 `set_output_mode` |
| 编码器不动/乱跳 | 编码器模式使能了 CCxE | `CCER=0` |
| MPU INT 无信号 | MPU 未配中断 / INT 悬空 | 配 data-ready + 推挽输出 |

---

## 附：`build.sh` 被 sudo 拦截

**现象**: 运行 `build.sh` 直接退出，提示"请勿用 sudo/root"。

**根因**: 这是**设计**——防 `.zig-cache` 属主污染（见错误 4）。

**解决**: 用普通用户构建；烧录用 `flash.sh`（仅 openocd 一步按需 sudo）。
