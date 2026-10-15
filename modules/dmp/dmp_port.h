/*
 * dmp_port.h —— DMP 库（inv_mpu.c / inv_mpu_dmp_motion_driver.c）
 *                在 microzig 裸机环境下的最小平台适配头。
 *
 * 参考工程原本通过 "sys.h" 引入整个 STM32/外设头体系；这里替换为一个**最小**
 * 集合，只提供 DMP 库真正需要的东西。
 *
 * 重要: 本固件为 **freestanding（无 libc 头文件）**，故**不能** include
 *       <string.h>/<math.h>/<stdio.h>/<stdlib.h>。这里改用**手工声明**所需函数。
 *       memset/memcpy 由 Zig 的 compiler-rt 提供；其余给出最小实现/宏。
 *
 * I2C 约定（与参考工程 i2cWrite/i2cRead 一致）:
 *   i2c_write(addr7, reg, len, data)  向 7 位地址 addr7 的寄存器 reg 写 len 字节
 *   i2c_read (addr7, reg, len, data)  从 7 位地址 addr7 的寄存器 reg 读 len 字节
 *   返回 0 成功，非 0 失败（与 DMP 库期望一致）。
 */
#ifndef DMP_PORT_H
#define DMP_PORT_H

/* ---- 基础类型（不用 stdint.h，freestanding 下无 libc 头）---- */
typedef unsigned char      uint8_t;
typedef signed char        int8_t;
typedef unsigned short     uint16_t;
typedef signed short       int16_t;
typedef unsigned int       uint32_t;
typedef signed int         int32_t;
typedef unsigned long      uint64_t;

/* ---- 平台函数声明（由 Zig 的 dmp.zig 以 C ABI 导出）---- */
int  i2c_write(unsigned char slave_addr, unsigned char reg_addr,
               unsigned char length, unsigned char const *data);
int  i2c_read(unsigned char slave_addr, unsigned char reg_addr,
              unsigned char length, unsigned char *data);
void delay_ms(unsigned long num_ms);
void get_ms(unsigned long *count);

/* ---- 标准库函数声明（实现来自 compiler-rt 或本项目的 stub）---- */
void *memset(void *s, int c, unsigned long n);
void *memcpy(void *dest, const void *src, unsigned long n);
void *memmove(void *dest, const void *src, unsigned long n);
int   memcmp(const void *s1, const void *s2, unsigned long n);
int   strcmp(const char *s1, const char *s2);
long  labs(long x);

float fabsf(float x);

/* ---- log 宏：无操作（避免依赖 printf）---- */
#define log_i(...) ((void)0)
#define log_e(...) ((void)0)

/* ---- 宏：DMP 库期望的 fabs / min ---- */
#ifndef fabs
#define fabs(x) (((x) > 0) ? (x) : -(x))
#endif
#ifndef min
#define min(a, b) (((a) < (b)) ? (a) : (b))
#endif

/* ---- DMP 库内部头（参考工程由 sys.h 一并引入）---- */
#include "inv_mpu.h"
#include "inv_mpu_dmp_motion_driver.h"
#include "dmpKey.h"
#include "dmpmap.h"

#endif /* DMP_PORT_H */
