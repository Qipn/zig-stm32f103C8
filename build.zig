const std = @import("std");
const microzig = @import("microzig");

// 选择 STM32 端口（相当于 Keil 里选芯片库）
const MicroBuild = microzig.MicroBuild(.{
    .stm32 = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;
    const stm32 = mb.ports.stm32;

    // ---------- 公共模块（类似 Keil 的 Libraries/）----------
    // 驱动源代码路径只声明一次; 具体 module 在每个 app 内单独创建，
    // 因为 microzig 的 import 是绑定到 firmware 的（fw.core_mod），
    // 共享 module 会被重复 addImport 而冲突。
    const Drivers = struct {
        const led = "modules/drivers/led.zig";
        const usart = "modules/drivers/usart.zig";
        const oled = "modules/drivers/oled.zig";
        const delay = "modules/drivers/delay.zig";
        const nvic = "modules/drivers/nvic.zig";
        const key = "modules/drivers/key.zig";
        const key_scan = "modules/drivers/key_scan.zig";
        const i2c_soft = "modules/drivers/i2c_soft.zig";
        const mpu6050 = "modules/drivers/mpu6050.zig";
        const adc = "modules/drivers/adc.zig";
        const motor = "modules/drivers/motor.zig";
        const encoder = "modules/drivers/encoder.zig";
        const dmp = "modules/drivers/dmp.zig";
    };

    // ---------- 应用列表（类似 Keil 的 User/）----------
    // 新增 app 时在此加一项：`zig build <name>`
    // imports 里写的是驱动源文件路径，每 app 独立建 module。
    // 每个驱动项: { 导入名, 源文件路径, 依赖的其它驱动导入名 }
    const Driver = struct {
        name: []const u8,
        path: []const u8,
        deps: []const []const u8 = &.{},
    };
    const Apps = struct {
        target: *const microzig.Target,
        name: []const u8,
        file: []const u8,
        /// 该 app 引用的驱动: { 导入名, 源文件路径, 依赖的驱动导入名 }
        drivers: []const Driver = &.{},
        /// 需要编入固件的 C 源文件（如 DMP 官方库）
        c_sources: []const []const u8 = &.{},
        /// C 源文件的 include 目录
        c_include: []const []const u8 = &.{},
        /// C 编译 flags
        c_flags: []const []const u8 = &.{},
        /// 覆盖优化级别（null = 用全局）
        optimize_override: ?std.builtin.OptimizeMode = null,
    };
    const apps = [_]Apps{
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "led-blink",
            .file = "apps/led-blink/main.zig",
            .drivers = &.{
                .{ .name = "led", .path = Drivers.led },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "usart-echo",
            .file = "apps/usart-echo/main.zig",
            .drivers = &.{
                .{ .name = "usart", .path = Drivers.usart },
                .{ .name = "led", .path = Drivers.led },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "oled-demo",
            .file = "apps/oled-demo/main.zig",
            .drivers = &.{
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "led", .path = Drivers.led },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "blink-systick",
            .file = "apps/blink-systick/main.zig",
            .drivers = &.{
                .{ .name = "led", .path = Drivers.led },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "irq-demo",
            .file = "apps/irq-demo/main.zig",
            .drivers = &.{
                .{ .name = "led", .path = Drivers.led },
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "nvic", .path = Drivers.nvic },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "key-demo",
            .file = "apps/key-demo/main.zig",
            .drivers = &.{
                .{ .name = "key", .path = Drivers.key },
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "led", .path = Drivers.led },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "key-fifo-demo",
            .file = "apps/key-fifo-demo/main.zig",
            .drivers = &.{
                .{ .name = "key_scan", .path = Drivers.key_scan },
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "led", .path = Drivers.led },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "mpu6050-demo",
            .file = "apps/mpu6050-demo/main.zig",
            .drivers = &.{
                .{ .name = "i2c_soft", .path = Drivers.i2c_soft, .deps = &.{"delay"} },
                .{ .name = "mpu6050", .path = Drivers.mpu6050, .deps = &.{"i2c_soft"} },
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "led", .path = Drivers.led },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "i2c-scan",
            .file = "apps/i2c-scan/main.zig",
            .drivers = &.{
                .{ .name = "i2c_soft", .path = Drivers.i2c_soft, .deps = &.{"delay"} },
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "adc-demo",
            .file = "apps/adc-demo/main.zig",
            .drivers = &.{
                .{ .name = "adc", .path = Drivers.adc },
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "encoder-demo",
            .file = "apps/encoder-demo/main.zig",
            .drivers = &.{
                .{ .name = "encoder", .path = Drivers.encoder },
                .{ .name = "motor", .path = Drivers.motor },
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "encoder-test",
            .file = "apps/encoder-test/main.zig",
            .drivers = &.{
                .{ .name = "encoder", .path = Drivers.encoder },
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "exti-demo",
            .file = "apps/exti-demo/main.zig",
            .drivers = &.{
                .{ .name = "nvic", .path = Drivers.nvic },
                .{ .name = "i2c_soft", .path = Drivers.i2c_soft, .deps = &.{"delay"} },
                .{ .name = "mpu6050", .path = Drivers.mpu6050, .deps = &.{"i2c_soft"} },
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "pin-read",
            .file = "apps/pin-read/main.zig",
            .drivers = &.{
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "delay", .path = Drivers.delay },
            },
        },
        .{
            .target = stm32.chips.STM32F103C8,
            .name = "dmp-demo",
            .file = "apps/dmp-demo/main.zig",
            .drivers = &.{
                .{ .name = "i2c_soft", .path = Drivers.i2c_soft, .deps = &.{"delay"} },
                .{ .name = "dmp", .path = Drivers.dmp, .deps = &.{ "i2c_soft", "delay" } },
                .{ .name = "oled", .path = Drivers.oled, .deps = &.{"delay"} },
                .{ .name = "delay", .path = Drivers.delay },
            },
            // InvenSense DMP 官方 C 库（不翻译，直接编入）
            .c_sources = &.{
                "modules/dmp/inv_mpu.c",
                "modules/dmp/inv_mpu_dmp_motion_driver.c",
            },
            .c_include = &.{"modules/dmp"},
            // dmp-demo 带 5200 行 C，debug 下会超 flash，固定用 ReleaseSmall
            .optimize_override = .ReleaseSmall,
            // 关键: 裸机 C 必须禁异常/展开表（.ARM.exidx/.extab 会占上百 KB flash）
            // 并开尺寸优化。
            .c_flags = &.{
                "-Os",
                "-ffreestanding",
                "-fno-unwind-tables",
                "-fno-asynchronous-unwind-tables",
                "-fno-stack-protector",
                "-fno-builtin",
                "-std=gnu11",
            },
        },
    };

    for (apps) |app| {
        const fw = mb.add_firmware(.{
            .name = app.name,
            .target = app.target,
            .optimize = app.optimize_override orelse optimize,
            .root_source_file = b.path(app.file),
        });

        // 为本 app 单独创建驱动 module：先全部建好，再加跨驱动依赖，
        // 最后接入 firmware（microzig 的 import 绑定到 firmware，
        // 共享 module 会被重复 addImport 而冲突）。
        var mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
        defer mods.deinit();
        for (app.drivers) |drv| {
            const mod = b.createModule(.{ .root_source_file = b.path(drv.path) });
            mods.put(drv.name, mod) catch @panic("OOM");
        }
        for (app.drivers) |drv| {
            const mod = mods.get(drv.name).?;
            for (drv.deps) |dep_name| {
                mod.addImport(dep_name, mods.get(dep_name).?);
            }
            fw.add_app_import(drv.name, mod, .{ .depend_on_microzig = true });
        }

        // 为 app 编入 C 源文件（如 DMP 官方库）。
        // 注: microzig 的 fw.add_c_source_file/add_include_path 在 Zig 0.17 下不可用
        //     （fw.exe.addCSourceFile 已移除），改用 fw.exe.root_module 的接口。
        for (app.c_include) |inc| fw.exe.root_module.addIncludePath(b.path(inc));
        for (app.c_sources) |src| {
            fw.exe.root_module.addCSourceFile(.{ .file = b.path(src), .flags = app.c_flags });
        }

        // 安装固件（默认格式 + ELF）到 zig-out/firmware
        const install_bin = mb.add_install_firmware(fw, .{});
        const install_elf = mb.add_install_firmware(fw, .{ .format = .elf });
        b.getInstallStep().dependOn(&install_bin.step);
        b.getInstallStep().dependOn(&install_elf.step);

        // 每 app 一个构建 step: `zig build <name>`
        // 依赖该 app 的安装（编译 + 拷贝到 zig-out/firmware）
        const app_step = b.step(app.name, b.fmt("Build {s}", .{app.name}));
        app_step.dependOn(&install_bin.step);
        app_step.dependOn(&install_elf.step);

        // `zig build flash-<name>` -> OpenOCD (ST-Link) 烧录
        // 注: 若 ST-Link 无权限, 建议用项目根的 ./flash.sh（会自动提权）。
        const flash = b.addSystemCommand(&.{
            "openocd",
            "-f",
            "interface/stlink.cfg",
            "-f",
            "target/stm32f1x.cfg",
            "-c",
            b.fmt("program zig-out/firmware/{s}.elf verify reset exit", .{app.name}),
        });
        flash.step.dependOn(b.getInstallStep());
        b.step(
            b.fmt("flash-{s}", .{app.name}),
            b.fmt("Flash {s} with OpenOCD", .{app.name}),
        ).dependOn(&flash.step);

        // 便捷别名：`zig build flash` 烧录第一个 app
        if (std.mem.eql(u8, app.name, apps[0].name)) {
            b.step("flash", "Flash the default app with OpenOCD").dependOn(&flash.step);
        }
    }
}
