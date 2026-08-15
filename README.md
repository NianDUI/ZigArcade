# ZigArcade

运行于 Ghostty 等终端的 Zig 多主机模拟器。FC/NES 是首个可玩目标，Neo Geo 是后续独立核心。

## 开发环境

- Zig：**0.16.0**（本项目的唯一支持版本；不兼容旧版 API 的代码不做兼容层）
- 首选终端：Ghostty，使用 Kitty Graphics Protocol 显示原始 RGB framebuffer
- 回退终端：ANSI truecolor 半块字符渲染

实现架构、分期计划、测试策略和参考项目索引见 [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)。项目采用 [MIT License](LICENSE)；外部资料的使用边界见 [REFERENCES.md](REFERENCES.md)。

GitHub CI 在 macOS 和 Linux 上固定 Zig 0.16.0，运行 `zig fmt --check build.zig src`、`zig build test` 与 `zig build`；不依赖 ROM、BIOS 或外部测试资产。

当前可用接口：

```sh
zig build test
zig build run -- inspect path/to/game.nes
zig build run -- framehash path/to/game.nes --frames 120
zig build run -- nes path/to/game.nes
zig build run -- nes path/to/game.nes --renderer ansi
```

仓库不包含商业 ROM、BIOS 或密钥；仅接受自制、公开许可或用户合法备份的资产。

`nes` 当前接受 iNES 1.0 的 Mapper 0/NROM（16/32 KiB PRG、8 KiB CHR-ROM 或 CHR-RAM）、Mapper 1/MMC1（至少 32 KiB PRG、CHR-ROM 或 CHR-RAM）、Mapper 2/UNROM（CHR-RAM、至少两个 16 KiB PRG bank）、Mapper 3/CNROM（16/32 KiB 固定 PRG、至少两个 8 KiB CHR-ROM bank）和 Mapper 7/AOROM（32–256 KiB PRG、CHR-RAM）。MMC1 支持串行 PRG/CHR bank 切换及单屏、水平、垂直镜像，CNROM 的 `$8000-$FFFF` 写入选择 CHR bank，AOROM 的 `$8000-$FFFF` 写入选择 32 KiB PRG bank 与单屏名称表；Mapper 0/1/2/3 提供 8 KiB 易失 PRG-RAM，AOROM 标准版型不提供 PRG-RAM。默认 `--renderer auto` 会在 TTY 中优先探测 Ghostty 的 Kitty 图像协议，失败时回退 ANSI；强制 `--renderer kitty` 在探测失败时返回错误。电池存档仍明确不支持。`WASD` 或方向键映射方向、`Z/X` 映射 A/B、Enter=Start、Tab=Select、Esc 退出；Ghostty 等支持 Kitty Keyboard Protocol 的终端会按下持续生效、松开即停止，并支持多键组合。其他终端回退为短按保持 8 个模拟帧（约 133 ms），按住时依赖系统自动重复续期。

可先使用 `zig build run -- inspect path/to/game.nes` 验证 ROM；不受支持的 iNES 特性会在切换终端 raw mode 前给出中文原因。

`framehash` 不需要 TTY：它固定推进 1–10000 帧并输出原始 ROM SHA-256 与最终 RGB framebuffer 的 Wyhash，适合为你合法持有的 ROM 或自制 ROM 记录回归基线；仓库不会收集或提交这些 ROM。

当前核心包含全部 151 个官方 2A03 opcode 的分派、Mapper 0/1/2/3/7、PPU 寄存器/VRAM 镜像/VBlank NMI/奇帧 dot skip、背景滚动 framebuffer、8×8/8×16 精灵（翻转、优先级、8 精灵限制的基础模型）、双手柄串行读取、逐总线周期 OAM DMA，以及 APU 帧计数器 IRQ、Pulse 1 定时器/长度计数和简化 PCM 采样链。模拟循环按约 60 Hz 推进，Kitty 每帧展示、ANSI 回退路径约 30 FPS；默认使用 `NullAudioSink` 静音，macOS 可通过 `--audio` 显式启用 CoreAudio AudioUnit PCM 输出。可用 `--audio-backend queue` 试验 AudioQueue（默认仍为 `unit`）以便比较稳定性。仍缺逐 dot 背景/精灵取数、sprite overflow 的硬件 bug、完整 APU 包络/扫频/其他通道/混音、其他 mapper，以及锁定的公开 ROM 回归；因此此阶段只适合自制/测试 ROM，不承诺商业 ROM 兼容性。

## 当前 P0 演示

请在 TTY（推荐 Ghostty）中运行：

```sh
zig build run -- --demo auto   # 探测 Kitty，失败时自动回退 ANSI
zig build run -- --demo kitty  # 强制 Kitty 图像协议
zig build run -- --demo ansi   # 强制 ANSI 真彩色半块渲染
zig build run -- --demo-neogeo auto # 合成 Neo Geo 固定层 320×224 演示
```

演示显示 `256×240` 色条；按任意键退出。它会使用 alternate screen，收到 Ctrl-C、SIGTERM 或终端挂起后会恢复终端状态。
