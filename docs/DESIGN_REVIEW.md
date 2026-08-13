# 详细实现设计：三角色独立审查报告

审查对象：[IMPLEMENTATION.md](IMPLEMENTATION.md)。本报告记录了三个独立角色的高优先级结论及处理结果；它不是实现完成声明。

| 角色 | 审查范围 | 结果 |
|---|---|---|
| 模拟器架构 | NES/Neo Geo 时序、总线、硬件边界 | 7 项高优先级，全部采纳 |
| 终端与性能 | Ghostty、Kitty 协议、TTY 生命周期 | 3 项高优先级，全部采纳 |
| Zig/测试/合规 | Zig 0.16、可测试性、许可证 | 6 项高优先级，全部采纳 |

## 模拟器架构审查

| 发现 | 裁决与文档处理 |
|---|---|
| Scanline 级 PPU 不足以正确处理寄存器/NMI/sprite/奇帧时序 | 采纳：P2 起 `tickDot()` 是唯一规范时钟；scanline 仅可作已验证的视觉优化。 |
| OAM DMA 仅写 513/514 周期会遗漏有副作用的源读取 | 采纳：改为 dummy/alignment + 256 read/write 的逐总线周期状态机，并要求 parity/mapper-source 测试。 |
| CPU 指令、interrupt、RMW 与 dummy read 范围不明确 | 采纳：P1 规定 micro-op/bus trace、interrupt priority；非官方 opcode 须在 P1 作明确支持/拒绝决定。 |
| NROM 的 PRG 镜像、CHR-RAM、palette/nametable 镜像缺失 | 采纳：加入 Mapper 0 行为与 header-level 测试要求。 |
| 后期才添加音频会破坏跨主机接口 | 采纳：P0 预留 `AudioSink`/NullAudioSink、模拟 timestamp 和环形缓冲规则。 |
| Neo Geo 缺地址图、IRQ、ROM 变换与 sound latch 定义 | 采纳：P5 拆为 P5a/P5b，先验证 68000 地址图/BIOS，再做 Z80、视频寄存器与固定层。 |
| 公共输入只有 8 个 NES 位，无法表达 Neo Geo | 采纳：改为稳定的 16-bit 系统无关 action 位。 |

## 终端与性能审查

| 发现 | 裁决与文档处理 |
|---|---|
| 查询响应与 raw 输入共用 TTY，原方案会误吞按键或误判能力 | 已实现：固定 probe image id、200 ms deadline、匹配 APC 响应；`ProbeDemux` 缓存无关用户字节并在探测结束后交回 `Session` 输入队列，含 APC 分段与同批尾随按键回归。 |
| 每帧先 delete 再 transmit 会增加 Ghostty 的 image-state 更新 | 采纳：固定 image/placement ID 重传 `a=T`；连续帧断言只有 1 image/1 placement。 |
| 仅 Ctrl-C 清理不足以处理 SIGTSTP/SIGCONT | 采纳：定义 lifecycle 状态机，加入 suspend/re-raise/resume/redraw 及 PTY 验收；明确 SIGKILL/硬崩溃不保证恢复。 |

## Zig、测试与合规审查

| 发现 | 裁决与文档处理 |
|---|---|
| 4 KiB 被误写为原始数据上限，Base64 后会超常见 APC 限制 | 采纳：改为 Base64 payload ≤4096 bytes，即原始块 3072 bytes；加入尾块、短写测试。 |
| 仅宣称 Zig 0.16.0，缺少实际构建/TTY API 验证 | 采纳：P0 加可行性 spike、平台条件分支、CI 固定 0.16.0、build/test/fmt 验收。 |
| PPU/控制器/DMA 的测试资产和通过规则不可复现 | 采纳：要求 fixture manifest 锁定 URL、版本、许可、SHA-256、命令与期望结果。 |
| GPL/非商业条款等许可证核对不闭环 | 采纳：P0 先由项目所有者决定仓库 LICENSE；建立 references/notices/fixture manifest。未确定前不拉取、不提交第三方资产或代码。 |
| 依赖箭头会让 core 与 systems 形成反向耦合 | 采纳：明确 `main` 装配，`frontend -> core`、`systems -> core`、`core` 不反向依赖。 |

## 遗留决策

1. 由项目所有者选择 ZigArcade 的发布许可证；这是引入任何可再分发依赖或测试资产前的门槛。
2. P1 结束时决定是否支持稳定的非官方 2A03 opcode；若不支持，MVP 的兼容性声明必须限制为测试 ROM/homebrew。
3. P0 的 Ghostty 基准数据决定是否将 60 FPS 设为默认；在此之前默认 30 FPS。
