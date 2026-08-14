# Neo Geo 68000 地址图证据（卡带系统）

本文件是 P5a 的实施前置条件，范围仅为 MVS/AES 卡带系统共享的 68000 地址选择与镜像。它不是 Neo Geo CD 地址图，不定义任何商业 BIOS/ROM 内容，也不把外部模拟器源码带入本仓库。

## 证据与采用规则

| 来源 | 固定版本 | 用途 | 许可边界 |
|---|---|---|---|
| NeoGeo Development Wiki：[`68k memory map`](https://wiki.neogeodev.org/index.php?title=68k_memory_map&oldid=8317) | revision 8317 | 主地址范围、物理大小与镜像 | 页面标注 CC0；仅摘录硬件事实，不拷贝实现 |
| NeoGeo Development Wiki：[`Memory mapped registers`](https://wiki.neogeodev.org/index.php?title=Memory_mapped_registers&oldid=9288) | revision 9288 | I/O 基址、decode mask、寄存器语义 | 页面标注 CC0；其中页面自述“decode masks 未完全验证”，实施时以测试锁定 |
| NeoGeo Development Wiki：[`68k/Z80 communication`](https://wiki.neogeodev.org/index.php?title=68k/Z80_communication&oldid=5271) | revision 5271 | `REG_SOUND` 双向 byte latch、Z80 port `$00`/`$0C` 与 NMI 触发条件 | 页面标注 CC0；只采用 latch 读写事实，不实现 Z80/NMI |
| MAME：[`neogeo.cpp`](https://github.com/mamedev/mame/blob/c8f7357b5c573fd7f236c4747f0f34fafe510c54/src/mame/snk/neogeo.cpp#L1533-L1584) | commit `c8f7357b5c573fd7f236c4747f0f34fafe510c54` | 独立交叉核验 MVS/AES 输入变体、RAM/Palette mirror 与 watchdog 地址 | MAME 许可证不兼容本项目 MIT；只作行为研究，禁止复制代码 |

同一事实至少由 Wiki 与 MAME 之一明确支持；若二者表现出系统类型或板型差异，代码必须建模为显式 variant，不能用“默认值”掩盖。当前 `address_map.zig` 的 `decode(variant, address)` 要求调用方明确选择 `.mvs` 或 `.aes`，只编码下表中可确认的译码，不执行设备副作用。

## 已锁定的主地址范围

| CPU 地址 | 物理对象 / 译码 | 当前状态 |
|---|---|---|
| `$000000-$0FFFFF` | 固定 P-ROM 窗口；向量切换为其中的特殊子行为 | 地址已建模；尚未实现真实 vector swap |
| `$100000-$10FFFF` | 64 KiB work RAM；`$110000-$1FFFFF` 为镜像 | 地址与镜像已建模 |
| `$200000-$2FFFFF` | 第二个 P-ROM / banked window | 地址已建模；bank switch 未实现 |
| `$300000-$3FFFFF` | I/O | 仅已列寄存器的译码已建模 |
| `$400000-$401FFF` | 8 KiB palette RAM；至 `$7FFFFF` 镜像 | 地址与镜像已建模；尚未接入 `PaletteRam` |
| `$800000-$BFFFFF` | AES memory-card window | 仅 `.aes` 译码；不读取或创建持久卡数据 |
| `$C00000-$C1FFFF` | 128 KiB system ROM；至 `$CFFFFF` 镜像 | 地址已建模；BIOS 内容/映射尚未接入 |
| `$D00000-$D0FFFF` | MVS backup RAM；至 `$DFFFFF` 镜像 | 仅 `.mvs` 译码，尚不创建持久存档 |

## 已锁定 I/O 基址

所有表项均按文档中的 decode mask 匹配镜像地址。已接入的 `cartridge_io.zig` 只接受 offset 为 0 的有效 byte lane；68000 word 访问仍必须满足偶地址规则。open-bus 值和未列系统变体不在本轮假定。

| 基址 | 名称 | 读 / 写概念 | 当前状态 |
|---|---|---|---|
| `$300000` | `REG_P1CNT` | P1 方向与 A–D，active-low | 仅译码；输入编码待总线接入 |
| `$300001` | `REG_DIPSW` / watchdog | DIP read；写入 kick watchdog | 仅 `.mvs`；`dipswitch_watchdog.zig` 接收调用方注入的 raw DIP byte（未设置即保持未映射）并记录每次 watchdog kick，不臆测 DIP 语义或 watchdog timeout；MVS 的 `$300080/$300081` TEST 空间明确不能被错译为 P1，AES 的 P1 镜像范围单独处理 |
| `$320000` | `REG_SOUND` | Z80 reply / 68k sound command | `cartridge_io.zig` 已接入命令 latch 与非破坏 reply read；NMI、Z80 端口执行待 P5b |
| `$340000` | `REG_P2CNT` | P2 输入，active-low | 仅译码 |
| `$380000` | `REG_STATUS_B` | start/select 与系统状态 | 仅译码；MVS/AES 位定义需分 variant |
| `$3A0001` 等 | system-control latch | palette bank、vector source、save/memory-card 控制等 | `system_control.zig` 已记录 `$3A0003/$3A0013` 的 BIOS/卡带 vector source 与 `$3A000F/$3A001F` 的 palette bank 0/1；写数据被忽略，只有 odd byte lane 有效；尚未连接 ROM 或 palette RAM |
| `$3C0000-$3C000E` | LSPC video | VRAM address/data/modulo、mode、timer、IRQ ack | 仅译码；VRAM/IRQ 未实现 |

## 代码落点与测试顺序

`src/systems/neogeo/address_map.zig` 是纯函数地址译码层：调用方必须传入 `.mvs` 或 `.aes`，它才返回设备目标和归一化后的物理 byte offset。`system_control.zig` 消费其中的 system-control 目标，建模 74HC259 风格的地址触发锁存：写数据无意义，只有 odd byte lane 有效，地址 bit 4 选择 set/reset；当前仅接受有明确证据的 vector source 和 palette bank 两组状态。`dipswitch_watchdog.zig` 是 MVS `REG_DIPSW` 的 raw-byte 注入与 watchdog-kick 观测边界；它不伪造默认 DIP 配置或 watchdog 复位时序。`cartridge_bus.zig` 是独立的、无资产的卡带总线组合切片：目前接入 work RAM 的 byte/word、palette RAM 的 word、已验证 I/O byte lane、MVS DIP/watchdog byte lane 与 system-control 写入；system-control 只更新本地锁存状态，读/word lane、ROM、open bus、memory-card、backup RAM、LSPC 都明确保持未映射。`bus.zig` 仍是旧的合成诊断总线，不能被误称为真实硬件总线。

后续必须按以下顺序接入：

1. 将固定/银行 P-ROM、system ROM、已建模的 vector switch 以显式设备接入 `cartridge_bus.zig`，并先锁定 ROM wait/open-bus 规则。
2. 扩充经资料验证的 byte/word lane：palette byte 写 mask、I/O word 低字节，并在两组 palette 存储均有明确模型后接入已建模的 palette bank 开关。
3. 再实现 LSPC VRAM port、timer/IRQ 与真正 68000 exception/interrupt 边界。

在第 3 步完成前，不宣称可以运行 BIOS 或任何 Neo Geo 游戏。
