# NES 公开测试 ROM 回归报告（2026-08-20）

## 测试基线

- ZigArcade：`main`，报告随当前实现提交更新
- Zig：`0.16.0`
- 主机：macOS 26.5.2 arm64
- 测试仓库：`christopherpow/nes-test-roms`
- 锁定 commit：`95d8f621ae55cee0d09b91519a8989ae0e64753b`
- 执行入口：`zigarcade romtest <rom> --frames <limit>`
- 判定协议：blargg `$6000-$6003` 状态码及 `$6004` 零结尾文本

测试 ROM 仅从锁定 commit 临时读取，没有加入本仓库。未使用商业 ROM。

## 结果汇总

| 范围 | 通过 | 失败 | 阻塞/不适用 |
|---|---:|---:|---:|
| 2A03 官方指令行为 | 1 | 0 | 0 |
| PPU VBlank/NMI 单项 | 10 | 0 | 0 |
| PPU read-buffer/DMA | 1 | 0 | 0 |
| PPU open bus | 0 | 1 | 0 |
| MMC3 IRQ 单项 | 5 | 0 | 0 |
| APU 基础单项 | 6 | 0 | 0 |
| APU reset 单项 | 0 | 3 | 3 |
| CPU/APU 指令时序与中断 | 4 | 1 | 0 |

这里的“阻塞”表示 ROM 要求按 RESET 后继续，而当前自动入口没有模拟主机 RESET；不能据此判定测试通过或失败。没有 `$6000` 协议的旧测试 ROM 也不纳入统计。

## 通过项

| ROM | 完成帧 | 结果 |
|---|---:|---|
| `instr_test-v5/official_only.nes` | 1885 | `All 16 tests passed` |
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
| `ppu_read_buffer/test_ppu_read_buffer.nes` | 1310 | Passed |
| `cpu_interrupts_v2/rom_singles/1-cli_latency.nes` | 18 | Passed |
| `cpu_interrupts_v2/rom_singles/2-nmi_and_brk.nes` | 114 | Passed |
| `cpu_interrupts_v2/rom_singles/3-nmi_and_irq.nes` | 134 | Passed |
| `cpu_interrupts_v2/rom_singles/4-irq_and_dma.nes` | 71 | Passed |
| `apu_test/rom_singles/1-len_ctr.nes` | 22 | Passed |
| `apu_test/rom_singles/2-len_table.nes` | 17 | Passed |
| `apu_test/rom_singles/3-irq_flag.nes` | 22 | Passed |
| `apu_test/rom_singles/4-jitter.nes` | 21 | Passed |
| `apu_test/rom_singles/5-len_timing.nes` | 115 | Passed |
| `apu_test/rom_singles/6-irq_flag_timing.nes` | 24 | Passed |
| `mmc3_test/1-clocking.nes` | 24 | Passed |
| `mmc3_test/2-details.nes` | 26 | Passed |
| `mmc3_test/3-A12_clocking.nes` | 24 | Passed |
| `mmc3_test/4-scanline_timing.nes` | 317 | Passed |
| `mmc3_test/5-MMC3.nes` | 24 | Passed |

## 确认失败项

### PPU VBlank/NMI

VBlank 状态切换、NMI 输出窗口、`$2002`/`$2000` 撤销尚未采样边沿的行为，以及奇帧跳点启停边界均已对齐；十个单项现全部通过。

### PPU open bus

`ppu_open_bus/ppu_open_bus.nes` 在 74 帧以 `Failed #3` 结束：open-bus 值应在一秒内衰减为零。当前实现保留值但没有衰减模型。

### MMC3 IRQ

CPU `$2006/$2007` 地址变化已经接入 MMC3 A12 观察路径。PPU 跨扫描线 A12 状态、首次背景 pattern fetch，以及 CPU 指令倒数第二周期的 IRQ 采样相位均已对齐；五个 MMC3 rev B 单项现全部通过。

### APU 与 CPU/APU 时序

| ROM | 失败证据 |
|---|---|
| `apu_reset/4017_timing.nes` | `Failed #2`：上电/复位后的 frame IRQ 应更晚设置 |
| `apu_reset/4017_written.nes` | `Failed #2`：上电时应等效写入 `$4017=$00` |
| `apu_reset/works_immediately.nes` | `Failed #2`：上电后寄存器写应立即生效 |
| `instr_timing/instr_timing.nes` | `Failed #5`：APU length period 与指令组合时序不匹配 |
| `cpu_interrupts_v2/cpu_interrupts.nes` | CLI latency、NMI/BRK、NMI/IRQ、IRQ/OAM DMA 已通过；完整套件当前推进到最终的 `5-branch_delays_irq` 后失败 |

`4015_cleared.nes`、`irq_flag_cleared.nes`、`len_ctrs_enabled.nes` 请求 RESET 后继续，当前标为阻塞。

## 未纳入结论

- 需要非官方 opcode 的 ROM：当前按既定兼容边界返回 `UnsupportedOpcode`。
- 没有 `$6000-$6003` 状态协议的旧 ROM：当前入口返回 `TestRomProtocolNotFound`，不能据此判模拟失败。
- 需要真实按键、人工观察、PAL、商业 ROM 或主机 RESET 的测试未执行。

## 结论与建议顺序

当前 CPU 官方指令行为、PPU VBlank/NMI、PPU 基础内存/DMA 和 MMC3 IRQ 路径均已有公开 ROM 通过证据。建议后续修复顺序：

1. 补全分支指令对 IRQ 轮询的周期级延迟。
2. APU 上电状态和主机 RESET 生命周期。
3. PPU open-bus 衰减模型。
