# ZigArcade 详细实现设计

## 1. 目标、版本与边界

ZigArcade 是在 macOS/Linux 终端运行的 Zig 多主机模拟器。首发使用 Ghostty 的 Kitty Graphics Protocol 显示 framebuffer；不支持时回退 ANSI 真彩色。FC/NES 的首个目标是“公开测试 ROM 与 NROM 自制 ROM 可验证运行”，不是立即承诺广泛商业 ROM 兼容；Neo Geo 是后续独立系统。

**唯一支持的 Zig 工具链是 0.16.0。** 所有 `std`、构建脚本、I/O 和错误处理都以 Zig 0.16 API 为准；不为 0.13/0.14/0.15 维护兼容代码。每次升级 Zig 必须先更新本节版本、跑完整测试并记录破坏性变更。

MVP（FC）包含 iNES 1.0、Mapper 0/NROM、2A03 CPU、dot 级 PPU 背景/精灵/NMI、逐总线周期 OAM DMA、两个手柄端口、`256×240` RGB 输出。当前实现还覆盖 MMC1、UNROM 与 CNROM 的基础 bank 行为，以及只送入 `NullAudioSink` 的 Pulse 1 音频链；仍不含持久存档、真实宿主音频、录像或联网。

仓库不分发商业 ROM、Neo Geo BIOS、密钥或其派生数据。测试资产必须有来源、许可证和 SHA-256 记录。P0 前必须确定本仓库的发布许可证，并创建 `THIRD_PARTY_NOTICES.md`、`REFERENCES.md` 与 `tests/fixtures/MANIFEST.md`；没有明确再分发许可的资产不得提交。

## 2. 分期交付与验收

| 阶段 | 交付 | 必须通过的验收 |
|---|---|---|
| P0 | Zig 0.16 可行性 spike、CLI、TTY guard、Kitty/ANSI 呈现、色条 | macOS/Linux 上固定 Zig 0.16.0 通过 build/test/fmt；Ghostty 显示 `256×240`；正常退出、SIGTERM、SIGTSTP/SIGCONT 后终端恢复 |
| P1 | 2A03、逐总线周期 CPU 总线、trace runner | `nestest` 在约定入口逐行匹配 PC、寄存器、周期；中断、RMW、dummy-read bus trace 通过 |
| P2 | iNES、NROM、dot 级 PPU、寄存器/NMI、背景 | 锁定版本的公开 CPU/PPU 测试 ROM 通过，含 VBlank/NMI 边界测试 |
| P3 | DMA、控制器、精灵、滚动 | NROM 自制 ROM 可操作，固定帧 RGB 哈希匹配 |
| P4 | Mapper 1/2/3/4、APU、NullAudioSink | 每个 mapper 有 bank/mirroring 单测和公开 ROM 回归；音频时钟、采样输出、underrun 统计可测 |
| P5a | Neo Geo 68000、BIOS/地址图、输入、IRQ 诊断 | 锁定的 68000 指令测试和 BIOS memory-map 诊断通过 |
| P5b | Neo Geo Z80、sound latch、VRAM/palette/fixed layer | Z80 map 与 CPU 间命令/应答测试通过；`320×224` 固定层诊断画面匹配 |
| P6 | Neo Geo 精灵视频、YM2610 | 用户合法 ROM/BIOS 的兼容性矩阵达标 |

“画面看起来像”不能作为验收；每阶段需有单测、trace、ROM 状态码或帧哈希之一。

## 3. 目录与依赖边界

```text
src/
  main.zig                 # CLI、装配、生命周期
  frontend/
    terminal.zig           # raw mode、alternate screen、信号清理
    input.zig              # 键盘 -> InputState
    presenter.zig          # auto/kitty/ansi 选择、帧节流
    kitty.zig              # Kitty 图像协议，与主机无关
    ansi.zig               # 真彩色半块回退
  core/
    system.zig             # Frame、Input、System vtable
    scheduler.zig          # 单调时钟、呈现统计
    rom.zig                # 只读数据、哈希、解析错误
    state.zig              # 后续版本化 snapshot
  systems/
    nes/                   # cpu、bus、ppu、apu、cartridge、mapper
    neogeo/                # m68k、z80、video、ym2610、romset
tests/fixtures/            # 仅可再分发资产或其清单
```

导入图为：`main -> frontend, core, systems`；`frontend -> core`；`systems -> core`；`core` 不导入 `frontend` 或 `systems`。`main` 装配具体 `System` 实例。系统核心不得导入 POSIX、TTY、ANSI、Ghostty；前端不得解析 `.nes` 或 Neo Geo ROM-set。

## 4. 跨主机契约

前端拉取系统帧；系统不读 stdin、不 sleep、不依赖 wall clock。`runFrame` 从上个帧边界执行到下个帧边界。画面缓冲只保证在下一次 `runFrame` 前有效。

```zig
pub const PixelFormat = enum { rgb888, rgba8888 };
pub const Frame = struct {
    pixels: []const u8,
    width: u16,
    height: u16,
    stride: u32,
    format: PixelFormat,
    frame_number: u64,
};
pub const ActionBits = packed struct(u16) {
    up: bool = false, down: bool = false, left: bool = false, right: bool = false,
    primary_1: bool = false, primary_2: bool = false,
    primary_3: bool = false, primary_4: bool = false,
    start: bool = false, select: bool = false, coin: bool = false, test: bool = false,
    _reserved: u4 = 0,
};
pub const InputState = struct { ports: [4]ActionBits = .{ .{}, .{}, .{}, .{} } };
```

`core/input.zig` 定义稳定的 packed `Actions(u16)`；`stride` 必须被呈现器尊重。NES 映射 `primary_1/2` 为 A/B、`select` 为 Select；Neo Geo 映射 `primary_1..4` 为 A..D、`coin` 为 Coin。公共位的语义在此锁定，不在主机接入时破坏 ABI。

音频从 P0 就预留为独立时钟域：`AudioSink` 接收带模拟 cycle timestamp 的交错 PCM；MVP 注入 `NullAudioSink`，但 APU/YM2610 必须按 CPU/master clock 推进、重采样后写入环形缓冲。需要定义目标采样率、最大缓冲帧数、underrun/overrun 计数与回压规则，且绝不以 wall clock 修正模拟周期。

## 5. Ghostty 与终端呈现

Ghostty 源码已确认实现 Kitty Graphics Protocol：`src/terminal/kitty/graphics_command.zig` 解析协议，`graphics_image.zig` 支持原始 RGB (`f=24`) 与 RGBA (`f=32`)。因此 FC `256×240×3` RGB 帧无需先编码 PNG。

### 5.1 后端选择和协议

`--renderer auto|kitty|ansi`：`auto` 以 `TERM=xterm-ghostty` / `TERM_PROGRAM=ghostty` 作候选；候选成立后，在**启用游戏输入前**通过 controlling TTY 的双向 fd 执行查询。向 TTY 发固定非零 probe image id 的最小直接 RGB 查询，在 200 ms 单调时钟截止前只接受匹配的 `ESC_Gi=<probe-id>;OK ESC\\` 响应；响应可分段，解析器必须有长度上限。无关用户字节先缓存，查询完成后交给输入解析器；超时或 ERROR 时 `auto` 降级 ANSI，`kitty` 返回 `TerminalUnsupported`。非 TTY/CI 使用 fake duplex TTY 测试，不能从 stdin/stdout 管道猜测能力。

探测请求固定为 `ESC_Ga=q,q=0,t=d,f=24,s=1,v=1,i=<probe-id>;AAAA ESC\\`（`AAAA` 是一个 RGB 像素）。接收状态机只将完整且 ID 匹配的 `OK` 或 `ERROR` 视为探测结果；APC 片段、用户按键和其他终端响应都保留原始顺序，完成探测后再交给相应解析器。

Kitty APC 格式：`ESC _ G <键值参数> ; <Base64 数据> ESC \\`。第一帧上传并显示，参数至少为 `a=T,f=24,t=d,s=<width>,v=<height>,i=<image-id>,p=<placement-id>,c=<cols>,r=<rows>,C=1`。

- 帧数据 184,320 bytes，Base64 后约 245,760 bytes。
- 每个 APC 的 **Base64 payload** 至多 4096 bytes；原始块固定为 3072 bytes（3 的倍数），尾块更短。首块含完整元数据，续块仅含必要的 `m=1/0`（及静默设置）；所有 APC 都经 `writeAll` 处理短写。
- 每帧以同一 image id/placement id 直接发送 `a=T`：Ghostty 对同 ID 重传会替换旧 image 并删除其 placement，随后创建一个 placement。不得先额外 delete；泄漏回归断言连续 N 帧后恰有 1 image 和 1 placement。仅在退出或终端挂起前发送 `a=d,d=A` 释放该会话的图像状态。
- 预分配 RGB、Base64 和协议缓冲，禁止每帧分配；模拟循环仍以约 60 Hz 逐帧推进，默认只呈现每第二帧（约 30 FPS），不得因降低呈现频率而放慢或跳过模拟；`--fps 60` 需经基准验证。
- 生命周期是显式状态机。启动前保存 termios；SIGINT/SIGTERM/SIGHUP 仅置退出标志并唤醒主循环；SIGTSTP 触发主循环删除图像、恢复 termios/屏幕、还原默认 handler 并重新 raise，SIGCONT 后重新进入 raw/alternate screen 并重绘。清理输出不能与 APC 混写；阻塞 write 必须可中断。SIGKILL/硬崩溃不承诺恢复。

ANSI 回退使用 `▀` 的前景/背景真彩色压缩上下两个像素。原尺寸需要 `256×120` 字符格，当前实现以无堆分配的 2×2 最近邻降采样输出 `128×60` 字符格；可配置缩放是后续工作。每帧整体构造后单次写入并移动光标至左上，禁止持续产生 scrollback。

### 5.2 输入与安全

当前 raw-byte fallback 使用 `WASD` 或 ANSI 方向键序列映射 D-pad，Z=A，X=B，Enter=Start，Tab=Select，Esc 退出；可靠按下/释放事件待接入 Kitty keyboard protocol 后提供。TTY fd 的所有权、macOS/Linux termios/sigaction 条件分支和 Zig 0.16.0 的实际 API 必须先在 P0 spike 中编译验证；`.github/workflows/ci.yml` 在 macOS/Linux 固定 Zig 0.16.0，并运行 `zig fmt --check build.zig src`、`zig build test` 与 `zig build`。

ROM 标题和错误文本输出前过滤 ESC/C0，防止 ROM 元数据注入控制序列。信号处理器只写原子退出标志，主循环完成资源回收。

## 6. NES 实现

### 6.1 CPU、时钟和总线

2A03 是无十进制模式的 6502 变体，NTSC 约 1.789773 MHz。CPU 以 micro-op / bus-cycle 状态机实现，寻址模式只报告页面跨越，读指令决定是否加罚时。每 CPU 周期推进 PPU 3 dot，APU 节拍从 CPU 周期派生。P1 要明确 RESET/IRQ/NMI 的 instruction-boundary 采样与优先级、BRK/RTI/stack、dummy read、RMW read-write-write 序列；每一条被支持指令要有周期与 bus trace。

| 地址 | 设备 |
|---|---|
| `$0000-$07FF` / `$0800-$1FFF` | 2 KiB RAM / 镜像 |
| `$2000-$2007` / `$2008-$3FFF` | PPU 寄存器 / 镜像 |
| `$4000-$4013,$4015,$4017` | APU |
| `$4014` | OAM DMA |
| `$4016-$4017` | 控制器 |
| `$4020-$FFFF` | Mapper/卡带 |

CPU `read/write` 和无副作用 `peek` 必须分开；CPU 绝不使用 `peek`。OAM DMA 是 bus-cycle 状态机：起始写 `$4014` 后先执行 1/2 个 alignment/dummy 周期，再交替 256 次有副作用 CPU bus read 与 OAM write，总计 513/514 周期；来源可以是 mapper/I/O。必须测试奇偶、mapper 来源和中断优先级。

### 6.2 PPU、卡带与控制器

PPU 为 341 dot × 262 scanline，约 60.0988 FPS。**从 P2 开始 `tickDot()` 就是唯一驱动寄存器、NMI、取数与 IRQ 可观察状态的规范实现**；scanline renderer 只可作为已验证的视觉优化，不能驱动时序。CPU bus 访问须有绝对 CPU/PPU tick；实现 pre-render odd-frame dot skip、PPU open bus、VBlank/NMI 抑制边界，后续 MMC3 以 PPU A12 上升沿驱动 IRQ。

必须实现：`$2000-$2007` 的 `v/t/x/w` 锁存、`$2002` 清 VBlank/重置写锁存、pattern/nametable/palette 镜像、VBlank NMI、背景 tile/attribute、精灵透明/优先级/8 精灵限制/sprite-0 hit。明确 `$3000-$3EFF` nametable mirror 与 `$3F10/$14/$18/$1C` palette mirror。内部先输出调色板索引，再映射 64 色 RGB。

`Cartridge` 仅解析校验 iNES；Mapper 提供 `cpuRead/cpuWrite/ppuRead/ppuWrite/mirroring`。当前支持 Mapper 0：16 KiB PRG-ROM `$8000-$FFFF` 镜像或 32 KiB 直映射、CHR-ROM 写忽略或 CHR size=0 时的 8 KiB CHR-RAM；Mapper 1/MMC1：5-bit 串行寄存器、16/32 KiB PRG 与 4/8 KiB CHR bank、单屏/垂直/水平 mirroring，支持 CHR-ROM 或 8 KiB CHR-RAM；标准 iNES MMC1 范围限定为 32–256 KiB PRG 和至多 128 KiB CHR，外部 bank 的板型变种暂不接受；Mapper 2/UNROM：可切换 `$8000-$BFFF` 的 16 KiB PRG bank、固定 `$C000-$FFFF` 的末 bank 和 8 KiB CHR-RAM；Mapper 3/CNROM：16/32 KiB 固定 PRG 映射、CPU 写 `$8000-$FFFF` 选择一个 8 KiB CHR-ROM bank（至少两个 bank），CHR-ROM 不可写；Mapper 7/AOROM：32–256 KiB PRG，CPU 写 `$8000-$FFFF` 选择一个 32 KiB PRG bank（低三位）及单屏名称表（bit 4），仅支持 8 KiB CHR-RAM。Mapper 0/1/2/3 有易失 8 KiB PRG-RAM `$6000-$7FFF`，MMC1 以 PRG bank bit 4 控制这段 RAM 的读写；标准 AOROM 不暴露 PRG-RAM。battery 标志仍拒绝，不创建持久存档。初版拒绝 NES 2.0、trainer、four-screen 和其他未知 mapper。

控制器把宿主当前状态和串行锁存状态分离：`$4016` bit 0 高时，每次读 port 1 都重新采样且返回 A、不移位；从 1 降 0 时冻结 8 位；`$4016` read 是 port 1、`$4017` read 是 port 2，顺序为 A、B、Select、Start、Up、Down、Left、Right，之后读 1。`$4017` 的 APU frame-counter 写须与读端口分开建模。

## 7. Neo Geo 后续核心

Neo Geo 是独立主机：68000 主 CPU、Z80 音频 CPU、YM2610、sprite/tile 视频与 P/C/M/V/S ROM 区。严禁塞入 NES mapper 或共享 NES 总线。

首个前置模块是 `systems/neogeo/romset.zig`：它仅校验调用方提供的 P（program）、C（sprites）、S（fixed）、M（audio CPU）、V（samples）及 BIOS 条目的名称、非零大小、SHA-256 元数据和区域完整性，并可对调用方持有的字节切片验证大小/SHA-256；不打开文件、不保留字节、不捆绑、也不猜测任何游戏 ROM 或 BIOS。后续本地加载器必须在文件读取/拼接前通过此 manifest。

`systems/neogeo/bus.zig` 是 P5a 前的合成数据诊断切片：定义 reset 时 BIOS 覆盖 `$000000-$0FFFFF` P-ROM、关闭 overlay 后读取 P-ROM，及 `$100000-$10FFFF` 64 KiB work RAM 的 68000 big-endian word 规则。它不含 68000 取指/执行、视频、I/O 或真实 BIOS；这些地址与时序会在正式 P5a 资料锁定后扩展。

`systems/neogeo/fixed.zig` 在 P5b 前提供 S-ROM 固定层的纯 8×8、4bpp 位平面解码：32-byte tile 的四个 8-byte plane 组合为 palette index，输出缓冲由调用方提供。尚未接入 tilemap、palette RAM、`320×224` 合成或真实 ROM；这一步仅锁定图块数据格式。

`systems/neogeo/palette.zig` 提供 palette word 的 RGB555→RGB888 扩展，并保留 bit 15 的 dark/shadow 标记给后续合成器处理；没有假定真实 palette RAM 地址或优先级规则。

`systems/neogeo/video.zig` 可将一个调用方给定的 S-ROM 格式 tile 重复合成，或将 row-major 的 `40×28` tilemap 与连续 tile store、16 色 RGB palette 合成为合成诊断 `320×224 RGB888 Frame`；它严格检查 tile store 和 tile index 边界，验证公共 Frame/Kitty 前端可承接 Neo Geo 分辨率。它不代表真实 VRAM tilemap、palette bank、scroll、sprite、raster 或真实 ROM 已实现。

`systems/neogeo/fixed_map.zig` 提供合成的 `40×28` row-major fixed-layer tilemap RAM 和严格的边界访问；它可导出只读 tile word 切片给 video renderer。真实 Neo Geo VRAM port、地址寄存器、自动增量与 tile 编码仍待 P5b 地址图实现，不能与这里的诊断布局混同。

`systems/neogeo/palette_ram.zig` 提供合成的 4096×16-bit palette RAM，可按严格边界读写原始 word，并解码任一连续的 16 色 bank 为 `palette.Color`。真实 palette RAM 的总线地址、写 mask 与 dark/shadow 合成规则仍待 P5b 地址图实现。

`systems/neogeo/timing.zig` 提供独立的 264-scanline 诊断 raster clock：前 224 行可见，进入第 224 行时锁存一次 VBlank edge，帧结束时清除 VBlank。它尚未定义 68000/Z80 时钟比、raster IRQ 寄存器或实际视频 fetch，只为后续 P5a/P5b 提供唯一的 VBlank 事件边界。

`systems/neogeo/neogeo.zig` 将诊断 bus、受限 68000 CPU、fixed tilemap、palette RAM、timing 与 `320×224` framebuffer 组装为 `NeoGeoDiagnostic`；`resetCpu` 通过当前 BIOS overlay 读取向量，`stepCpu` 执行一条已支持的诊断指令，`stepCpuInstructions(n)` 明确执行 n 条并返回周期锚点累计值，便于可复现的合成 BIOS/work-RAM 诊断。它不是无限游戏循环，也未定义 STOP、IRQ 或完整时钟。`renderFixed` 只接收调用方持有的 tile store，且仍不包含 ROM-set 文件加载、Z80 执行或真实硬件寄存器。

`systems/neogeo/input.zig` 把公共 `Actions(u16)` 映射到 Neo Geo A–D、Start、Coin 与方向的系统语义；端口地址及 active-low 数据线编码暂不定义，不能由 frontend 绕过该映射直接写 bus。

`systems/neogeo/sound_latch.zig` 定义 68000→Z80 command 与 Z80→68000 reply 的单字节 latest-value latch/pending 语义；没有假定 port 地址、Z80 中断、Z80 执行或 YM2610 寄存器。

`systems/neogeo/m68k.zig` 是 P5a 的受限 68000 诊断 CPU：它验证 reset SSP/PC vector、big-endian fetch、NOP、MOVEQ、`MOVE.L #imm,Dn`、`MOVE.L Dn,(An)`、`MOVE.L (An),Dn`、`MOVE.L Dn,(An)+`、`MOVE.L (An)+,Dn`、`MOVE.L Dn,-(An)`、`MOVE.L -(An),Dn`、`MOVEA.L #imm,An`、`MOVEA.W #imm,An`、`LEA (d16,An),An`、`MOVE.W #imm,Dn`、`MOVE.W #imm,(An)`、`MOVE.W Dn,(An)`、`MOVE.W (An),Dn`、`MOVE.W Dn,(An)+`、`MOVE.W (An)+,Dn`、`MOVE.W Dn,-(An)`、`MOVE.W -(An),Dn`、`MOVE.W Dn,(d16,An)`、`MOVE.W (d16,An),Dn`、`TST.L Dn`、`TST.W Dn`、`CMP.L #imm,Dn`、`CMP.W #imm,Dn`、`ADDQ.L/W #n,Dn`、`SUBQ.L/W #n,Dn`、BRA、BCC、BCS、BNE、BEQ、BPL、BMI（短/字位移）、`DBF Dn,<disp>`、`JSR (An)` 和 RTS 的基础控制流；JSR/RTS 回归同时锁定 big-endian 栈返回地址。当前 MOVE/TST 形式按操作数宽度更新 N/Z、清 V/C（保留 X）；`MOVEA.W` 符号扩展立即数、LEA 只做地址计算，二者均不改变 CCR；`(d16,An)` 使用有符号 word 位移，`(An)+` 在传送后自增、`-(An)` 在传送前预减，word 步长为 2、long 步长为 4 字节（均含 A7）；写入 Dn 的 word 形式保留高 16 位；CMP 按相应宽度的减法更新 N/Z/V/C 但保留 X 和操作数；ADDQ/SUBQ 的 quick 字段为 0 时表示 8，均按操作数宽度更新 X/N/Z/V/C；BCC/BCS 读取 C、BPL/BMI 读取 N、DBF 只递减 Dn 低字且不改变 CCR。未知 opcode 明确报错。cycle 返回值仅作诊断锚点，尚不代表完整 68000 指令集、异常、特权、精确总线周期或 Neo Geo 游戏可执行。

条件分支还覆盖 BVC/BVS：它们分别在 V 清除/置位时跳转，接受与其他已支持 Bcc 一致的短位移或字位移；其余未列出的条件码仍明确报 `UnsupportedOpcode`。

同一受限分支实现还覆盖 BGE/BLT：它们按有符号比较的 `N == V` / `N != V` 条件跳转，同样支持短位移和字位移。

BGT/BLE 也已接入：它们分别判断 `!Z && N == V` 与 `Z || N != V`，由 16/32 位 CMP 的条件码直接驱动。

BHI/BLS 完成无符号大小比较分支：它们分别判断 `!C && !Z` 与 `C || Z`。诊断核心现已支持全部 68000 Bcc 条件及 BRA 的短/字位移形式。

`BSR.s/.w` 同样支持相对短/字位移调用：先将取完操作码（及字位移扩展字）后的 PC 以 big-endian long 压栈，再跳转；它与 `RTS` 的回归共同锁定相对调用返回路径。

`LEA (d16,PC),An` 使用扩展字自身的地址加有符号 word 位移计算有效地址，且不改变 CCR；它只提供位置无关的诊断地址计算，不代表完整 PC-relative 寻址族。

`JMP (An)` 提供无栈的地址寄存器间接跳转，并保持 CCR；其余 JMP 形式仍明确未实现。

`CLR.W/L Dn` 已用于受限核心的寄存器清零：word 形式只清低 16 位，long 形式清整个 Dn；两者均按对应宽度置 Z、清 N/V/C 并保留 X。

`SWAP Dn` 交换 Dn 的高、低 word，再按 long 结果更新 N/Z、清 V/C 并保留 X。

`EXT.W Dn` 将低 byte 符号扩展至低 word，`EXT.L Dn` 将低 word 符号扩展至 long；它们按扩展后的操作数宽度更新 N/Z、清 V/C 并保留 X。

`ORI.W/L #imm,Dn` 对 Dn 对应宽度执行立即数按位或：word 形式保留高 16 位，long 形式覆盖整个寄存器结果；两者更新 N/Z、清 V/C 并保留 X。

`ANDI.W/L #imm,Dn` 提供对应宽度的立即数按位与，word 形式同样保留高 16 位；两种宽度都更新 N/Z、清 V/C 并保留 X。

`EORI.W/L #imm,Dn` 完成 Dn-only 的立即数异或形式，数据宽度和 CCR 规则与 ORI/ANDI 一致。

`NOT.W/L Dn` 对 Dn 对应宽度逐位取反；word 形式保留高 16 位，两个形式均按逻辑结果更新 N/Z、清 V/C 并保留 X。

`NEG.W/L Dn` 对 Dn 对应宽度作二补数取负；非零操作数置 X/C，最小负数置 V，按结果更新 N/Z。

`Scc Dn` 已覆盖全部 16 个条件码：依据 CCR 将 Dn 低 byte 写为 `$FF` 或 `$00`，保留其余 24 位且不改变 CCR；当前只实现 Dn 目标形式。

`ADD.W/L Dn,Dn` 支持数据寄存器源、目标形式：word 只写目标低 16 位，long 写全宽，均按对应宽度更新 X/N/Z/V/C。

`SUB.W/L Dn,Dn` 提供对称的数据寄存器减法，宽度写回和 X/N/Z/V/C 规则与相应 SUBQ 形式一致。

`CMP.W/L Dn,Dn` 比较数据寄存器源、目标而不写回任一操作数；按对应宽度更新 N/Z/V/C 并保留 X，可直接驱动 Bcc/Scc。

`MOVE.B #imm,Dn`、`TST.B Dn`、`CLR.B Dn` 构成当前 Dn-only byte 基础子集：均仅访问 Dn 低 byte、保留高 24 位，按 byte 宽度更新 N/Z、清 V/C 并保留 X。

`ORI.B`、`ANDI.B`、`EORI.B #imm,Dn` 将立即数逻辑族扩展到 Dn 低 byte：立即数使用 word 扩展字的低 byte，写回和 CCR 规则遵循 byte 宽度。

`NOT.B Dn`、`NEG.B Dn` 使当前 unary 子集支持 byte：均保留 Dn 高 24 位；NEG 的非零结果置 X/C，输入 `$80` 置 V。

`ADD.B/SUB.B Dn,Dn` 将数据寄存器算术扩展至 byte，保留目标 Dn 高 24 位，并按 byte 宽度更新 X/N/Z/V/C。

`CMP.B Dn,Dn` 仅比较低 byte，不写回任一寄存器；它保留 X，并按 byte 宽度更新 N/Z/V/C。

`MOVE.L Dn,(d16,An)` 与 `MOVE.L (d16,An),Dn` 复用有符号 word 位移的有效地址规则，并以 big-endian long 读写普通诊断内存。

`zigarcade --demo-neogeo auto|kitty|ansi` 直接呈现不含任何 ROM/BIOS 的合成 320×224 固定层图案，并推进一帧诊断 raster clock，用于当前 Ghostty/ANSI 前端验证；它不是 Neo Geo 游戏运行入口。

ANSI 回退路径以最近邻 2×缩小任一紧凑 RGB888 偶数尺寸帧；当前 NES `256×240` 呈为 `128×60` 个终端字符单元，Neo Geo 诊断 `320×224` 呈为 `160×56` 个字符单元。它复用预分配的最大 `320×240` 源帧缩小缓冲，不在逐帧路径分配内存；Kitty 路径则保留原始分辨率。

P5a 先锁定 68000 地址图：P-ROM 的 16-bit endian/interleave、work RAM、palette RAM、VRAM 地址/数据/控制寄存器、输入/coin、BIOS/region overlay、watchdog、VBlank/raster IRQ；并以 BIOS memory-map 和异常诊断验证。P5b 再定义 68000↔Z80 sound command/reply latch、Z80 bank/port map，以及 video master clock、scanline 和 VBlank IRQ。ROM manifest 除文件名/大小/SHA-256 外，必须声明区域、byte/word endian、interleave、continuation/reload 和 decode transform。固定层/palette 验证后才进入 C-ROM 精灵 bitplane decode、链式、缩放、自动动画、优先级与 raster effect，最后接 YM2610。`320×224` 画面直接由公共 `Frame` 交给 Kitty 后端。缺 BIOS/ROM 时必须报错，不提供或假定商业 BIOS。

《合金弹头》仅在 P6 完成并由用户提供合法 ROM/BIOS 后作为兼容性目标；不承诺早期运行。

## 8. 性能、状态与错误

仿真时钟从不按 wall clock 跳过周期。落后时只丢弃呈现帧，不跳过仿真帧。`--stats` 输出 emulated/presented/dropped frames、平均与 P99 呈现耗时。Kitty 60 FPS 原始吞吐约 11.1 MB/s、Base64 文本约 14.7 MB/s，故先 30 FPS 测量。

错误分类：`InvalidArguments`、`UnsupportedRomFormat`、`UnsupportedMapper`、`MissingFirmware`、`TerminalUnsupported`、`TerminalIo`、`CorruptRom`。`zigarcade inspect ROM` 在进入 raw TTY 前校验 iNES 并输出 mapper、PRG/CHR 大小和镜像；`zigarcade framehash ROM --frames N` 不需要 TTY、固定推进 1–10000 帧并输出原始 ROM SHA-256 与最终 framebuffer Wyhash，用于用户本地合法 ROM 的可复现回归记录；trace 与统计写 stderr，不能混进 APC 图像流。

后续 snapshot 需包含魔数、版本、system id、ROM SHA-256、长度和校验；hash 不符拒绝加载。MVP 不创建持久存档。

## 9. 测试矩阵

| 层级 | 断言 |
|---|---|
| Zig 单测 | ALU 标志、寻址、镜像、DMA 513/514 奇偶/mapper source、控制器 high-strobe/live-A/8 位后读 1、Mapper、palette |
| trace | `nestest` 的 PC/寄存器/周期及 NMI/IRQ、dummy read、RMW 序列 |
| ROM 集成 | 锁定版本的公开 CPU/PPU 测试 ROM：状态码、帧上限、VBlank status-read race、NMI edge/enable-during-vblank、sprite-0/overflow |
| framebuffer | 固定帧 RGB 哈希、尺寸、stride、调色板版本 |
| 前端 fake duplex TTY | Kitty 3072-byte 原始块/Base64/短写、响应分段、查询与用户键交错、清理顺序；ANSI 不滚屏 |
| PTY/Ghostty E2E | raw mode、Esc、缩放、Ctrl-C、SIGTERM、SIGTSTP/SIGCONT 后终端恢复 |

`tests/fixtures/MANIFEST.md` 必须为每项测试资产登记 URL、锁定 tag/commit、许可证/SPDX、SHA-256、运行命令、期望状态码或帧数。CI 不依赖商业资产。

## 10. 可参考开源项目与使用边界

| 项目/资料 | 用途 | 重点借鉴 | 边界 |
|---|---|---|---|
| Mesen 2 | NES 准确性与调试参照 | PPU/NMI/mapper 行为、测试思路 | 只比对行为；实施前核对许可证，禁止直接复制代码 |
| FCEUX | NES 兼容性资料 | CPU/mapper 边界、调试/trace 设计 | 不将 GPL 代码混入本项目 |
| Nestopia UE | NES 兼容性参照 | iNES、mapper 行为与回归思路 | 不复制实现；按许可证单独评估 |
| nesdev wiki + blargg/nestest | 硬件事实与测试 | 寄存器、时序、公开测试 ROM | 文档/资产均记录具体来源与许可 |
| FinalBurn Neo | Neo Geo 结构参照 | ROM 区布局、视频/音频模块边界、兼容性方法 | 逐 tag 核对其实际许可证与非商业条款；只作行为/架构研究，不能拷贝 |
| GnGeo | Neo Geo 早期实现参照 | ROM 装配、68000/Z80/视频协作 | 同上，许可证优先 |
| Ghostty | 终端后端参照 | Kitty 协议接受参数、分块、资源限制 | 仅协议行为依据；应用仍自己生成 APC 序列 |

新增参考项目时，必须在 `REFERENCES.md` 写入：仓库 URL、锁定 commit/tag、许可证/SPDX、要研究的具体模块、是否允许代码复用；`THIRD_PARTY_NOTICES.md` 列出实际分发的依赖/资产及 notice。许可不清或与本项目发布计划不兼容时，只可阅读公开文档/观察行为，不得引入源代码。严禁把“参考了 GPL 项目”误写成已获代码复用授权。

## 11. 首个实施切片

1. 建立仓库 LICENSE、`REFERENCES.md`、`THIRD_PARTY_NOTICES.md`、测试资产 manifest；用 Zig 0.16.0 初始化并锁定最小 `build.zig`、CI 的 `zig build test`/`zig fmt --check`。
2. 完成 macOS/Linux TTY/termios/sigaction 可行性 spike、terminal lifecycle 状态机、ANSI 色条、fake duplex TTY；再实现 Kitty query、3072-byte 原始块传输、短写和清理测试。
3. 实现 NES CPU/RAM 的 micro-op bus trace runner；先完成官方指令、interrupt/dummy/RMW 测试，再加载 ROM。当前已分派 151 个官方 2A03 opcode；非官方 opcode 仍明确 `UnsupportedOpcode`，兼容性范围限制为自制/测试 ROM，直到有公开 ROM 回归证据。
4. 接入 iNES/NROM、CPU bus、dot 级 PPU 寄存器/NMI，跑 manifest 锁定的公开测试 ROM。
5. 完成逐周期 DMA、双控制器、背景、精灵和帧哈希，交付 NROM 可玩样例。
6. 仅当 FC 回归稳定后，创建 Neo Geo 的 68000 单测切片。

每个提交都记录：模拟精度改变、跑过的 ROM/trace、已知未支持项和 Zig 版本。
