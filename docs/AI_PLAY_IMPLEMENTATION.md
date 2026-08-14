# AI 游玩模式详细实现方案

## 1. 目标与边界

本方案为 ZigArcade 增加一个可重复游玩的 AI 控制路径。它优先支持 NES，并保持
核心模拟器、终端呈现和模型服务三者分离。第一版使用 oMLX 的 OpenAI 兼容 API：

```text
模拟器 ──只读观测──> 观测编码/经验检索 ──> oMLX 决策 ──> 受限按键计划 ──> 模拟器
                     │                         │
                     └────跨局经验库<──结果/奖励──┘
```

必须满足：

- 不改变 CPU、PPU、Mapper 或输入设备的时序；AI 仅通过既有 `core/input.zig` 的
  `Actions` 注入按键。
- 不读取、写入或分发 ROM；经验数据只以 ROM SHA-256 为命名空间，保存派生的状态
  指纹、动作、结果和可选截图哈希。
- 没有游戏专用适配器时仍能运行“通用模式”；适配器只能补充语义，不能成为运行前提。
- oMLX API key 仅从环境变量读取，不出现在命令行、日志、提交或经验库中。
- 模型、服务端和适配器生成的任何文本均不直接写终端；状态栏只显示本地生成的、受限
  字符集的枚举和数值。
- 人类键盘始终优先：`Esc` 退出，`P` 切换 AI 暂停；人工游戏按键取消当前 AI 计划并
  进入人工接管，直到再次按 `P` 才恢复 AI。

非目标：第一期不做模型训练、远程模型端点、云端上传、自动下载模型、跨 ROM 共享经验，也不声称
可以通用识别所有游戏对象的语义。

## 2. 当前基础与设计决策

现有 `src/systems/nes/nes.zig` 已提供逐帧 `runFrame()` 和 RGB 帧；PPU 拥有背景、
精灵及调色板渲染所需状态；`src/core/input.zig` 是宿主无关的输入边界；
`src/main.zig` 已在帧循环中映射终端输入。因此首版不接管渲染器，而在每个
`runFrame()` 后采样，并在下一帧前写入控制器动作。

采用“结构化通用观测 + 可选游戏适配器 + 经验检索”的原因：

1. 原始 2 KiB CPU RAM 没有跨游戏语义，直接交给模型既不通用也浪费上下文。
2. PPU 的滚动、背景 tile 与 OAM 精灵位置是所有 NES ROM 都存在的客观信息，比只给
   截图更紧凑。
3. 对马里奥等已知游戏，适配器可提供坐标、生命和关卡奖励；未知 ROM 仍能以帧差、
   PPU 结构和失败检测积累经验。

## 3. 命令行与配置契约

新增命令（名称在实现前保持稳定）：

```sh
zig build run -- ai nes <rom.nes> \
  --endpoint http://127.0.0.1:8889/v1 \
  --model Qwen3.6-27B-OptiQ-4bit \
  --mode structured \
  --decision-frames 12 \
  --renderer auto
```

可选参数：

| 参数 | 默认值 | 规则 |
| --- | --- | --- |
| `--endpoint` | `http://127.0.0.1:8889/v1` | 仅接受精确的 `http://127.0.0.1:<port>/v1` 或 `http://[::1]:<port>/v1`；拒绝 hostname、userinfo、query、fragment、重定向和代理。 |
| `--model` | 必填 | 先请求 `/models` 校验精确模型 ID。 |
| `--mode` | `structured` | `structured`、`vision`、`hybrid` 三选一。 |
| `--decision-frames` | `12` | 范围 `1..60`；模型未返回前保持上一个安全动作，最多 `30` 帧。 |
| `--renderer` | `auto` | 复用 `auto`、`kitty`、`ansi`；与普通 NES 呈现的选择一致。 |
| `--headless` | `false` | 不进入 raw TTY、不呈现画面，供 HTTP mock 和可重复回放测试使用。 |
| `--experience-dir` | `~/.local/share/zigarcade/experience` | 可用 `ZIGARCADE_EXPERIENCE_DIR` 覆盖。 |
| `--adapter` | `auto` | `auto`、`none` 或已注册 ID。 |
| `--seed` | 随机 | 固定值用于可重复探索和测试。 |

令牌仅支持环境变量 `ZIGARCADE_OMLX_API_KEY`。请求使用
`Authorization: Bearer <token>`，而非把 token 放进 URL。第一期绝不访问远程端点：
HTTP 客户端禁用环境代理、禁止重定向，并在连接后的 peer 地址不是 loopback 时失败。
若变量缺失，允许无认证的本机端点，但状态只显示本地枚举 `auth=none`。远程端点和
远程截图上传都必须在未来版本以独立、显式的用户许可重新设计。

## 4. 模块、依赖与数据所有权

新增目录，不让 `systems/nes` 依赖 HTTP、JSON、文件系统或模型实现：

```text
src/ai/
  observation.zig       通用 Observation、状态指纹和 JSON 编码
  nes_observer.zig      PPU/OAM/帧差采样；只读 NES 适配层
  adapter.zig           GameAdapter 接口、注册表、ROM SHA-256 选择
  adapters/smb1.zig     示例：Super Mario Bros. iNES ROM 专用语义
  policy.zig            动作约束、经验优先级和模型回退策略
  omlx_client.zig       OpenAI 兼容 HTTP 客户端；无模拟器类型依赖
  experience.zig        追加日志、索引和原子压实
  runner.zig            AI 时钟、人工覆盖、回合生命周期
  tui.zig               后续阶段的状态面板（第一期仅文本状态行）
```

`nes_observer.zig` 所需的 PPU 只读访问器应显式添加在 `ppu.zig` / `nes.zig` 中，例如
`snapshotVideo()`；禁止把 PPU 字段公开为可写。它仅能在主线程、`runFrame()` 返回后的
帧边界调用，复制到调用方提供的固定缓冲区，避免每帧分配。快照包含低分辨率 framebuffer
摘要、有序 OAM（保留原 OAM index）、palette、有效滚动和渲染开关，以及 mapper 的
可见 bank/mirroring/CHR-RAM 摘要；不得通过有副作用的 CPU/PPU 读寄存器获取。
`runner.zig` 输出 `core.input.Actions`，由现有 NES 输入翻译继续完成控制器位映射。

## 5. 通用观测（模式 2）

每个决策点生成定长 `Observation`，而非把内存 dump 或整帧 RGB 塞入文本模型：

```zig
pub const Observation = struct {
    rom_sha256: [32]u8,
    frame: u64,
    input: input.Actions,
    held_frames: u8,
    video: VideoSummary,
    motion: MotionSummary,
    adapter: ?AdapterFacts,
};

pub const VideoSummary = struct {
    scroll_x: u16,
    scroll_y: u16,
    sprites: []const Sprite, // 上限 64，含 x/y/tile/attribute/size
    tile_digest: [16]u8,     // 两张 nametable 的稳定摘要
    palette_digest: [8]u8,
};
```

`MotionSummary` 保存当前与 1、4、12 帧前的低分辨率亮度摘要的差异、屏幕滚动变化、
精灵集合的位移统计、连续静止帧和场景切换标志。为精确跨局检索生成版本化的 canonical
bytes（固定小端编码，禁止 hash Zig struct/padding）：

```text
version(1) | 完整 ROM SHA-256 | mapper ID 与可见 bank/mirroring/CHR-RAM 摘要 |
ctrl/mask/v/t/fine_x | palette | 原 OAM 顺序的精灵 | 可见 framebuffer digest |
量化 scroll | adapter 离散状态（若有）
```

完整 digest 仅用于精确相等，短 hash 只能作索引且命中后必须复比完整 digest。相似检索
另存可解释的特征（量化 scroll、16×15 occupancy、运动桶、adapter 离散状态），仅在
这些特征上作加权距离；绝不对 cryptographic digest 做“近似距离”。不将原始 tile ID
解释为“敌人/玩家”；它们只用于稳定匹配。结构化模式发给模型的 JSON 设 4 KiB 上限：
OAM 以原 OAM index 稳定排序，超出时按固定规则截断并标记。

## 6. 视觉与混合回退

`vision` 每个决策点编码当前帧和一张 12 帧前的 PNG；图片尺寸限制为 `128×120`，
以降低 VLM 延迟。`hybrid` 发送结构化 JSON，并且只在下列情况附图：新状态、连续
失败、经验冲突、每 120 个决策一次的校正采样。

第一期 oMLX 候选：

- `Qwen3.6-27B-OptiQ-4bit`：默认视觉/混合候选，模型体积约 2.85 GB。
- `Mage-VL-OptiQ-4bit`、`gemma-4-e4b-it-4bit`：视觉备选。
- `Qwen-AgentWorld-35B-A3B-oQ4`：仅结构化文本候选；模型本体约 21 GB，不以“文本”
  假设其延迟较低。

启动时调用 `GET /v1/models` 校验精确 ID，并用 oMLX `/v1/models/status` 的扩展字段或
显式 capability probe 确认 visual 能力；不自动加载模型。`POST /v1/chat/completions`
固定使用 `stream:false`、`tool_choice:"none"`、`temperature:0`、受限 `max_tokens` 与
`response_format: json_schema`（`strict:true`、`additionalProperties:false`）。严格验证
一个未截断 choice、非空 content、响应 header/body 大小上限；任何 schema 降级 warning、
连接、超时或格式错误都视为失败，立即安全释放为 `none`，主线程不退出。

## 7. 动作契约与安全时钟

模型被要求只输出严格 JSON：

```json
{"buttons":["right","b"],"frames":12}
```

解析器不使用自由文本 fallback；拒绝重复 JSON key、未知字段、重复按钮和空按钮数组。
默认 allow-list 为方向键与 `a/b`；`start/select` 仅能由未来的显式 CLI 开关开启。
`frames` 为 `1..60`；`left + right`、`up + down` 均为非法而非猜测归一化。任何解析失败、
过期或超时结果都立即释放所有 AI 按键。模型的理由、服务端错误、模型名和适配器名均不
进入终端动态文本；若未来显示，必须剥离 C0/C1/ESC、限制字节和显示宽度。

帧循环顺序固定为：

```text
帧边界采样上一帧结果 → 更新经验/奖励 → 固定决策边界检索或提交请求 →
按 epoch 合并人工输入优先级 → 在下一次 runFrame 前一次性写入控制器 → runFrame → 呈现
```

同一帧的优先级固定为 `Esc > 生命周期信号 > P 暂停/恢复 > 人类游戏按键 > AI`。当前
raw 终端输入在不支持 Kitty Keyboard Protocol 时没有可靠 key-up，单次人类游戏按键会
按通用终端策略保持 8 个模拟帧；支持该协议时使用真实按下/重复/释放事件。首次人工按键
同时废弃 AI plan、递增 epoch 并暂停 AI，防止迟到的模型结果重新夺回控制。

模型调用不可阻塞模拟器时钟：每局最多一个 in-flight 请求、零长度待发队列。主线程将
有上限的 JSON/PNG 序列化到拥有所有权的不可变 `ObservationPacket` 槽位后才交给 worker；
worker 不得读取 `Nes`、`Frame`、控制器或终端。请求包含 `episode_id`、`plan_epoch`、
`decision_seq`、观测帧和固定生效帧；仅当 epoch/seq 仍匹配且在其生效边界到达前完成时
才采纳，迟到结果一律丢弃。退出、挂起、暂停或人工接管时取消并 join worker。

请求具有 2 秒连接、8 秒总超时、响应大小/线程数硬上限和每局最多 3 个失败退避。调用
未完成时最多复用上一个计划 30 帧，之后释放所有按键。可重复性定义为：模拟器与探索
RNG 在相同 `DecisionTrace`（观测键、计划生效帧、动作、人工覆盖、超时）下可回放；
真实模型网络时序只作尽力可复现，不能作为确定性验收依据。

## 8. 可选游戏适配器（模式 3）

适配器以 ROM SHA-256 精确匹配，而非只匹配文件名或 CRC。接口只读：

```zig
pub const GameAdapter = struct {
    id: []const u8,
    rom_hashes: []const [32]u8,
    observe: *const fn (view: AdapterMemoryView, out: *AdapterFacts) AdapterError!void,
    reward: *const fn (previous: AdapterFacts, current: AdapterFacts) Reward,
};
```

`AdapterMemoryView` 是在主线程帧边界冻结的只读 RAM 副本和 ROM identity，而不是 `Nes`
指针。`RomIdentity` 在 CLI 读取完整 ROM image 时立即计算 SHA-256，并传给 runner、
adapter 选择、经验目录与 checkpoint。`AdapterFacts` 首版限制为标量与短枚举：玩家 x/y、速度、生命/状态、世界/关卡、分数、
是否死亡、是否通关。适配器必须记录其使用的 RAM 地址和 ROM 版本证据，并对地址范围、
进制和无效值写单元测试。找不到精确 hash 时 `auto` 必须回落到通用观测，绝不猜测地址。

第一个样例为用户持有的 Super Mario Bros. iNES ROM；文档与测试只使用 ROM hash、
合成内存夹具和公开地址说明，不提交 ROM、截图或游戏资产。

## 9. 跨局经验与存档

第一期不是训练模型参数，而是可审计的经验学习。每局产生 JSON Lines 事件，目录为：

```text
<experience-dir>/<rom-sha256>/
  manifest.json             schema、ROM 元数据、adapter ID、创建时间
  episodes/YYYY-MM-DD.jsonl append-only ActionOutcome
  index.bin                 StateKey -> TopK（可原子重建）
  checkpoints/              第二阶段的模拟器存档，不跨 ROM 使用
```

每条 `ActionOutcome` 含 `state_key`、动作、持续帧、进度 delta、奖励、死亡/通关/卡住、
来源（`retrieval`、`model`、`explore`、`human`）、schema/policy/model 配置版本和时间。
奖励固定在 `[-1, 1]`，记录 n-step 回报、计数、均值及保守下界；不同来源分桶统计，避免
单次模型错误污染人工或经验策略。日志中不存 token、原始 RAM、整幅截图或模型完整文本。

检索流程：精确 `StateKey` 优先；无精确命中时仅按上述可解释特征的有界加权距离匹配；
仅在至少 3 次样本、回报置信下界大于零且来源策略满足配置时复用 TopK 最佳动作。每
20 个决策保留一次受种子控制的探索，连续两次死亡或 180 帧无进度则禁用当前动作并请求
模型重新规划。

经验根目录必须为 owner-only `0700`，新文件为 `0600`；拒绝符号链接、路径逃逸与多
进程无锁写入。压实使用“临时文件 → fsync → rename → fsync 父目录”；达到 128 MiB
上限时停止追加并继续游玩，状态显示本地枚举 `experience=full`。

第二阶段才添加模拟器快照，且只允许在 `runFrame()` 返回的安全点（不支持指令/DMA 中间
保存）。各组件必须显式 encode/decode，加载时由 ROM 重新构造并重新绑定指针，绝不
序列化含指针的 Zig struct。格式须含 CPU 寄存器/IRQ/NMI/周期、PPU 寄存器和时序状态、
nametable/palette/OAM、APU 分频/IRQ、2 KiB RAM/DMA、控制器锁存/shift/strobe、每个
mapper 的寄存器/PRG-RAM/CHR-RAM、帧号、区域/时钟、schema 和完整 ROM hash。加载会
取消 HTTP、清空动作计划或将 AI RNG/motion history/pending outcome 一同版本化保存。
若没有完整序列化契约，不创建“伪 checkpoint”。

## 10. TUI 与终端呈现

TUI 是终端内的交互控制面，不是替代 Kitty/ANSI 游戏画面的渲染器。第一期只在预留
底部状态行显示：模式、帧号、当前 plan/剩余帧、动作来源、人工接管、epoch、请求/超时、
最近延迟、经验命中或拒绝原因。所有字段由本地枚举和数值构成。布局统一为
`game_rect + status_row`：Kitty 和 ANSI 都预留一行；终端过小则按 renderer 能力缩放或以
明确退出码拒绝启动；resize、挂起恢复均清屏重绘，且 Kitty placement 始终只有一个并
锚定左上角。

第二期可增加 `zigarcade ai tui`：ROM/模型选择、开始/暂停、经验统计和错误详情。它
仅在未运行游戏帧时接受菜单键，游戏运行期间不截获既有玩家控制键。

## 11. 实施顺序与验收

| 阶段 | 交付 | 验收 |
| --- | --- | --- |
| A | `Observation`、PPU 只读快照、帧差、状态指纹 | 合成夹具产生稳定 canonical bytes；bank/mirroring/OAM 顺序变化均改变键；无堆分配。 |
| B | 动作计划、AI runner、人工覆盖、CLI | 帧边界注入；人工接管、暂停、退出和迟到响应均不能让旧计划复活。 |
| C | oMLX 客户端和模型能力探测 | loopback/无代理/无重定向；mock 验证 Authorization、schema warning、超时、上限和严格响应解析。 |
| D | JSONL 经验库和检索 | 重启后命中相同 ROM；不同 ROM 绝不命中；截断尾行、并发锁、容量上限和索引重建可恢复。 |
| E | SMB1 适配器和奖励 | 匹配 hash 才启用；合成 RAM 验证坐标/死亡/奖励；未知 hash 回落。 |
| F | save state、完整 TUI、更多系统 | 只在核心状态序列化完成后开始。 |

新增测试按层放置：`src/ai/*.zig` 单元测试、`src/systems/nes` 的只读快照回归、主程序
参数测试，以及一个本机 HTTP mock 集成测试。额外行为矩阵必须覆盖：远端视觉拒绝、
恶意 `ESC/CSI/APC` 文本绝不进入终端、人工接管后的旧响应丢弃、30 帧后自动松键、
`80×24`/`128×60`/`128×61` resize、SIGTSTP/SIGCONT、Kitty probe 输入保留、ANSI/Kitty
状态行不覆盖游戏区、headless mock，以及 save→load 后固定 N 帧的 CPU/PPU/mapper/input
哈希一致。持续检查：

```sh
zig fmt --check build.zig src
zig build test
zig build
git diff --check
```

人工验收使用用户本机合法持有的 ROM：先以 `--mode structured` 跑 5 局并确认经验在第
2 局开始复用；再以 `--mode hybrid` 确认画面、状态行及 Ghostty placement 不回归。测试
记录只保留 ROM hash、帧数、动作和汇总结果。

## 12. 风险与决策门

| 风险 | 处理 |
| --- | --- |
| 文本模型不能理解 tile ID | 以结构化模式为快速基础，遇到新/冲突状态升级到混合视觉；不承诺纯文本能通关所有 ROM。 |
| 模型延迟超过游戏帧率 | 异步请求、固定动作窗口、超时释放按键和经验优先。 |
| “死亡/进度”在未知游戏不可知 | 仅记录通用场景切换、静止/重置启发式；奖励置信度低时不复用。 |
| 适配器地址随 ROM 版本变化 | SHA-256 白名单、合成夹具、未知版本回落。 |
| 本地服务令牌泄漏 | 仅环境变量、禁用代理/重定向、禁止 URL token、日志不记录请求头或服务端原文。 |
| 经验库损坏或体积膨胀 | append-only 日志、原子索引、按 ROM 限额 128 MiB、可重建与显式清理命令。 |

第一期的已锁定决策是：截图只能发送给经实际连接校验的本机 loopback oMLX；任何远程
端点均拒绝。后续若需要远程模型，必须单独经过安全设计与用户显式许可。

## 13. 三角色审查与处理结论

| 角色 | 结论 | 处理 |
| --- | --- | --- |
| 模拟器架构与确定性 | 指出异步 HTTP 会破坏“固定 seed 即可复现”、`*const Nes` 不代表线程安全、状态键遗漏 mapper 可见状态、存档边界不完整。 | 已采纳：第 4、5、7、8、9 节增加帧边界、冻结 packet、DecisionTrace、canonical bytes、ROM identity 和显式存档契约。 |
| AI 系统、经验学习与安全 | 指出远程 HTTPS 仍可外发截图、模型文本可注入终端、JSON schema/能力探测/晚到结果/索引距离/文件权限不充分。 | 已采纳：第一期仅 loopback、终端只显示本地枚举、严格 schema 与 warning 失败、单 in-flight、可解释近邻、owner-only 经验库。 |
| TUI、可用性与测试 | 指出人工覆盖生命周期、worker 退出、ANSI 布局、headless 和可观察性不足。 | 已采纳：第 7、10、11 节规定接管 epoch、worker join、统一 `game_rect + status_row`、`--headless` 和行为矩阵。 |

三位审查者均认为方案可作为实现基础；所有 P0/P1 发现均已转化为编码前契约。尚未采纳的
范围扩大项只有远程模型支持与模型参数训练，均明确留到后续独立设计。
