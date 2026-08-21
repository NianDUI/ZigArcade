# NES 公开测试 ROM 回归报告（2026-08-21）

## 测试基线

- ZigArcade：`main`，报告随当前实现提交更新
- Zig：`0.16.0`
- 主机：macOS 26.5.2 arm64
- 测试仓库：`christopherpow/nes-test-roms`
- 锁定 commit：`95d8f621ae55cee0d09b91519a8989ae0e64753b`
- 执行入口：`zigarcade romtest <rom> --frames <limit>`；旧式蜂鸣报码使用 `zigarcade audiotest <rom> --frames <limit>`
- 判定协议：blargg `$6000-$6003` 状态码及 `$6004` 零结尾文本；音频报码以一个有效音调表示状态码 0

测试 ROM 仅从锁定 commit 临时读取，没有加入本仓库。未使用商业 ROM。

## 结果汇总

| 范围 | 通过 | 失败 | 阻塞/不适用 |
|---|---:|---:|---:|
| 2A03 官方指令行为 | 1 | 0 | 0 |
| 2A03 official/unofficial 非 jam 行为 | 1 | 0 | 0 |
| PPU VBlank/NMI 单项 | 10 | 0 | 0 |
| PPU read-buffer/DMA | 1 | 0 | 0 |
| PPU open bus | 1 | 0 | 0 |
| MMC3 IRQ 单项 | 5 | 0 | 0 |
| APU 基础单项 | 8 | 0 | 0 |
| APU reset 单项 | 6 | 0 | 0 |
| CPU/APU 指令时序与中断 | 8 | 0 | 0 |
| OAM/DMC DMA 冲突 | 2 | 0 | 0 |
| DMC DMA 读副作用 | 5 | 0 | 0 |
| DMC 启动/状态音频报码 | 4 | 0 | 0 |

`romtest` 现会识别 `$6000=$81`，等待至少 100 ms 后模拟主机 RESET，并保留测试用于计数的 PRG RAM。没有 `$6000` 协议的旧测试 ROM 不会自动判定；本文仅在稳定 `screen-text` 的 Passed/CRC 与锁定源码一致时手工纳入。

## 通过项

| ROM | 完成帧 | 结果 |
|---|---:|---|
| `instr_test-v5/official_only.nes` | 1874 | `All 16 tests passed` |
| `instr_test-v5/all_instrs.nes` | 2401 | `All 16 tests passed` |
| `ppu_vbl_nmi/rom_singles/01-vbl_basics.nes` | 144 | Passed |
| `ppu_vbl_nmi/rom_singles/02-vbl_set_time.nes` | 171 | Passed |
| `ppu_vbl_nmi/rom_singles/03-vbl_clear_time.nes` | 171 | Passed |
| `ppu_vbl_nmi/rom_singles/04-nmi_control.nes` | 34 | Passed |
| `ppu_vbl_nmi/rom_singles/05-nmi_timing.nes` | 221 | Passed |
| `ppu_vbl_nmi/rom_singles/06-suppression.nes` | 224 | Passed |
| `ppu_vbl_nmi/rom_singles/07-nmi_on_timing.nes` | 199 | Passed |
| `ppu_vbl_nmi/rom_singles/08-nmi_off_timing.nes` | 223 | Passed |
| `ppu_vbl_nmi/rom_singles/09-even_odd_frames.nes` | 80 | Passed，输出 `00 01 01 02` |
| `ppu_vbl_nmi/rom_singles/10-even_odd_timing.nes` | 144 | Passed，输出 `08 08 09 07` |
| `ppu_read_buffer/test_ppu_read_buffer.nes` | 1267 | Passed |
| `ppu_open_bus/ppu_open_bus.nes` | 250 | Passed |
| `cpu_interrupts_v2/rom_singles/1-cli_latency.nes` | 18 | Passed |
| `cpu_interrupts_v2/rom_singles/2-nmi_and_brk.nes` | 114 | Passed |
| `cpu_interrupts_v2/rom_singles/3-nmi_and_irq.nes` | 134 | Passed |
| `cpu_interrupts_v2/rom_singles/4-irq_and_dma.nes` | 71 | Passed |
| `cpu_interrupts_v2/rom_singles/5-branch_delays_irq.nes` | 381 | Passed |
| `cpu_interrupts_v2/cpu_interrupts.nes` | 726 | `All 5 tests passed` |
| `instr_timing/rom_singles/1-instr_timing.nes` | 1013 | Passed，含 unofficial opcode timing |
| `instr_timing/rom_singles/2-branch_timing.nes` | 140 | Passed |
| `instr_timing/instr_timing.nes` | 1299 | `All 2 tests passed` |
| `apu_test/rom_singles/1-len_ctr.nes` | 22 | Passed |
| `apu_test/rom_singles/2-len_table.nes` | 17 | Passed |
| `apu_test/rom_singles/3-irq_flag.nes` | 22 | Passed |
| `apu_test/rom_singles/4-jitter.nes` | 21 | Passed |
| `apu_test/rom_singles/5-len_timing.nes` | 115 | Passed |
| `apu_test/rom_singles/6-irq_flag_timing.nes` | 24 | Passed |
| `apu_test/rom_singles/7-dmc_basics.nes` | 27 | Passed |
| `apu_test/rom_singles/8-dmc_rates.nes` | 30 | Passed |
| `apu_reset/4015_cleared.nes` | 31 | Passed |
| `apu_reset/4017_timing.nes` | 42 | Passed，输出有效写入延迟 12 clocks |
| `apu_reset/4017_written.nes` | 59 | Passed |
| `apu_reset/irq_flag_cleared.nes` | 33 | Passed |
| `apu_reset/len_ctrs_enabled.nes` | 36 | Passed |
| `apu_reset/works_immediately.nes` | 37 | Passed |
| `sprdma_and_dmc_dma/sprdma_and_dmc_dma.nes` | 143 | Passed，覆盖普通 OAM 阶段的 2-cycle DMC stall |
| `sprdma_and_dmc_dma/sprdma_and_dmc_dma_512.nes` | 140 | Passed，覆盖倒数第 3/最后 OAM 周期的 1/3-cycle stall |
| `dmc_dma_during_read4/dma_2007_read.nes` | 1000 | screen CRC `5E3DF9C4`，属于源码允许结果 |
| `dmc_dma_during_read4/dma_2007_write.nes` | 1000 | screen text `Passed` |
| `dmc_dma_during_read4/dma_4016_read.nes` | 1000 | screen text `08 08 07 08 08`、`Passed` |
| `dmc_dma_during_read4/double_2007_read.nes` | 1000 | screen CRC `85CFD627`，属于源码允许结果 |
| `dmc_dma_during_read4/read_write_2007.nes` | 1000 | screen text 两行均为 `33 11 22 33 09 55 66 77`、`Passed` |
| `dmc_tests/buffer_retained.nes` | 900 | audio status 0（1 tone），Passed |
| `dmc_tests/latency.nes` | 900 | audio status 0（1 tone），Passed |
| `dmc_tests/status.nes` | 900 | audio status 0（1 tone），Passed |
| `dmc_tests/status_irq.nes` | 900 | audio status 0（1 tone），Passed |
| `mmc3_test/1-clocking.nes` | 24 | Passed |
| `mmc3_test/2-details.nes` | 26 | Passed |
| `mmc3_test/3-A12_clocking.nes` | 24 | Passed |
| `mmc3_test/4-scanline_timing.nes` | 317 | Passed |
| `mmc3_test/5-MMC3.nes` | 24 | Passed |

## 确认失败项

### PPU VBlank/NMI

VBlank 状态切换、NMI 输出窗口、`$2002`/`$2000` 撤销尚未采样边沿的行为，以及奇帧跳点启停边界均已对齐；十个单项现全部通过。

### MMC3 IRQ

CPU `$2006/$2007` 地址变化已经接入 MMC3 A12 观察路径。PPU 跨扫描线 A12 状态、首次背景 pattern fetch，以及 CPU 指令倒数第二周期的 IRQ 采样相位均已对齐；五个 MMC3 rev B 单项现全部通过。

### APU 与 CPU/APU 时序

APU frame counter、CPU 中断与分支轮询、official/unofficial 指令周期现均已有公开 ROM 通过证据。DMC cold load 在 `$4015` 重新启用后按 CPU/APU get-put parity 延迟 2/3 cycles，load 使用 3-cycle DMA、reload 使用 4-cycle DMA；启动 latency、buffer retained、status 与 status IRQ 已由四个音频报码 ROM 验证。OAM DMA 中间阶段及尾部 1/3-cycle 特例也已由两个公开 ROM 验证。DMC halt/dummy 对 `$2007` 的 2–3 次 phantom read、对 `$4016` 的单次额外移位，以及相邻 CPU 周期 `$2007` 连读返回锁存均已有公开 ROM 证据。

## 未纳入结论

- 12 个会锁死 2A03 的 jam opcode 尚未建模，当前仍返回 `UnsupportedOpcode`。
- 没有 `$6000-$6003` 状态协议的旧 ROM：`romtest` 返回 `TestRomProtocolNotFound` 并输出 `screen-text`；蜂鸣报码 ROM 可通过 `audiotest` 自动判定，其余只有文本中的 `Passed` 或 CRC 与锁定源码允许值一致时才手工纳入结论。
- 需要真实按键、人工观察、PAL 或商业 ROM 的测试未执行。

## 结论与建议顺序

当前 CPU 官方指令行为、PPU VBlank/NMI、PPU 基础内存/DMA 和 MMC3 IRQ 路径均已有公开 ROM 通过证据。建议后续修复顺序：

1. 扩充 DMC DMA controller interference 与更复杂 OAM 交错的公开回归。
2. 扩充 PPU sprite overflow 与非渲染期总线细节测试。
3. 明确 12 个 CPU jam opcode 的停机模型和工具侧诊断。
