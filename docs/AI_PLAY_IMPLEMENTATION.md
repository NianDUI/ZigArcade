# 文本模型游玩模式执行计划

> 状态：已完成协议元数据、组合动作约束、只读 NES 展示快照、带 episode shape alias 的通用场景 Keyframe/Delta 文本编码，以及 headless `observe`；token 基线、动作 runner 和 oMLX 接入尚未开始。
>
> 首期目标：让本机 oMLX 承载的文本模型通过紧凑、可重建的结构化观察控制 NES，支持组合按键，并在没有 ROM 专用配置时仍可运行。

## 1. 目标与边界

ZigArcade 增加一条与终端渲染解耦的 AI 控制路径：

```text
NES 帧边界
  -> PresentationSnapshot
  -> NES 通用视觉观察
  -> Keyframe / Delta 文本投影
  -> 本机 oMLX 文本模型
  -> 组合动作位掩码 + 持续帧数
  -> 现有 Actions / Controller
```

必须满足：

- AI 只通过现有 `core/input.zig` 的 `Actions(u16)` 注入输入，不改变 CPU、PPU、Mapper、APU 或控制器时序。
- 通用模式不得依赖 ROM 文件名、游戏内存地址或人工标注；ROM 专用 profile 只能叠加确定语义。
- 不把 RGB、PNG、Base64、CPU RAM dump 或不可解释的 digest 当作文本模型的主要观察。
- 观察协议支持精确 keyframe、可验证 delta、序号和状态哈希，禁止上下文静默漂移。
- 动作支持组合键、双手柄扩展和自动释放；模型异常不能造成按键永久卡住。
- 第一版采用“暂停模拟 -> 请求模型 -> 执行动作”的同步决策，先保证状态一致和可回放。
- oMLX 只允许本机 loopback；API key 只从环境变量读取，禁止写入日志。
- 仓库不提交商业 ROM、截图、模型权重或由 ROM 派生的图案资源。

首期非目标：

- 不承诺纯文本模型可理解或通关所有 NES 游戏。
- 不做 VLM 图片输入、模型训练、联网服务、自动下载模型、长期经验库或完整 TUI。
- 不在首期实现异步实时推理、自动识别所有游戏对象、通用奖励和 save state。
- 不把启发式推断的对象类别当作确定事实。

## 2. 已锁定的架构决策

### 2.1 内部状态与模型文本分离

内部使用有类型、定长或有明确上限的数据结构；文本 DSL 只是面向具体 tokenizer 的投影。不得让 HTTP JSON 或模型提示格式渗入 NES 核心。

```text
systems/nes -> 只读 PresentationSnapshot
ai/observation -> 通用 ObservationEnvelope
ai/text_codec -> tokenizer 友好的 Keyframe/Delta
ai/runner -> 动作生命周期
ai/omlx_client -> HTTP
```

### 2.2 使用展示快照而非实时 PPU 字段

观察必须与玩家实际看到的 framebuffer 对齐，读取 VBlank 锁存的 presentation 状态：

- 有效 scroll、nametable、PPUCTRL、PPUMASK；
- presentation OAM；
- presentation pattern 与 palette；
- 可见帧内 raster events；
- frame number、mapper 可见状态和 ROM identity。

不得在观察器中调用有副作用的 CPU/PPU 寄存器读，也不得直接暴露可写 `Ppu` 指针。

### 2.3 通用层只描述视觉事实

通用层可以确定：位置、颜色、图案、移动、滚动、出现和消失。它不能无证据地确定：玩家、敌人、地面、危险、生命、分数或胜负。

自动推断必须包含置信度和证据来源；ROM profile 可提供确定语义，但必须按完整 ROM SHA-256 精确匹配。

### 2.4 模型输入按 token 成本评估

字符数和压缩字节数不是目标。每个候选编码必须使用实际部署模型的 tokenizer 测量：

- keyframe token 数；
- 平均/95 分位 delta token 数；
- prompt processing 时间和首 token 延迟；
- 单次动作响应的总延迟。

## 3. 通用观察模型

### 3.1 观察信封

计划中的公共结构：

```zig
pub const ObservationEnvelope = struct {
    version: u16,
    system: SystemId,
    rom_sha256: [32]u8,
    episode_id: u64,
    sequence: u64,
    base_sequence: u64,
    frame: u64,
    kind: enum { keyframe, delta },
    scene: VisualScene,
    inference: InferredFacts,
    profile: ?ProfileFacts,
    state_hash: [16]u8,
};
```

`state_hash` 对 canonical bytes 计算；canonical 编码显式规定字段顺序、整数宽度和小端格式，禁止直接 hash Zig struct 或 padding。

### 3.2 NES 通用视觉场景

`VisualScene` 至少包含：

- 当前可见区的背景 cell；
- shape 字典增量；
- palette/attribute 引用；
- 原始 OAM sprite 记录；
- raster/scroll 分段；
- 相对历史帧的 cell 与 sprite 变化；
- 场景大幅变化、静止、闪烁和滚动标志。

不能只传原始 tile ID。CHR bank 切换后，同一 tile ID 可能代表不同图案。稳定身份定义为：

```text
shape_id = hash(decoded 8x8 pattern indices + sprite/background size mode)
appearance_id = shape_id + palette reference + flip attributes
```

shape 首次出现时加入字典；后续观察只引用短的 episode-local alias，例如 `a0`、`a1`。调色板变化不重复传图案轮廓。

### 3.3 背景编码

当前 keyframe 是 VBlank 锁存的结构化展示快照，而不是固定读取某一张 `32x30` nametable。它会应用：

- 当前 scroll 和 nametable 选择；
- 水平/垂直 mirroring；
- raster event 导致的分屏和中途 scroll/ctrl/mask 变化；
- pattern bank 和 palette；
- 背景/精灵显示开关。

背景以每个 `8×8` cell 左上角的 raster 状态采样，raster 列表仅供语义参考；因此 cell 内发生的 scroll/ctrl/mask 变化同样不能逐像素重建。首期快照还不保留可见期 `$2007` 写入、mapper CHR/mirroring 切换的逐 dot 历史；遇到此类效果时，文本场景是帧末锁存状态的近似。精确帧内内存/mapper 事件及逐像素观察是后续验收项。

背景文本使用行级 RLE 或稀疏坐标，两者取实际 token 数较小者。空白 alias 固定为 `.`，不得在每个 cell 中重复字段名。

### 3.4 精灵与视觉对象

通用 keyframe 保留最多 64 个有序 OAM 记录：

```text
oam_index, x, y, shape_alias, palette, flip_x, flip_y, priority, size
```

第二层可按邻接、共同速度和持续共现把多个 sprite 聚合为视觉实体，但必须保留原 OAM 索引和聚合置信度。HUD、粒子和闪烁 sprite 不得被默认标为游戏对象。

### 3.5 自动推断层

自动推断是可选增强，输出示例：

```text
controlled_candidates=e2:.82,e5:.31
entity e2 velocity=+1,0 parts=4 confidence=.91
surface y=13 x=0..18 confidence=.64
```

候选玩家可根据“动作与 sprite 位移的时序相关性”估计；可通行性可根据持久背景、接触和运动结果积累。首期只设计接口，不把自动探索和碰撞学习列为交付门槛。

### 3.6 ROM 专用 profile

Profile 以完整 ROM SHA-256 注册，只读冻结的 RAM 副本和通用观察，不持有 `Nes` 指针。它可以补充：

- 玩家世界坐标、速度和状态；
- 生命、关卡、时间、分数；
- 确认的敌人、地形、死亡和通关；
- ROM 专用奖励。

找不到精确 hash 时必须退回通用层，禁止按文件名、CRC 或相似地址猜测。

## 4. Keyframe / Delta 文本协议

### 4.1 原则

- 模型收到的每条观察都包含 `version/sequence/base/frame/hash`。
- keyframe 可以独立解释；delta 必须明确引用 base。
- 文本模型或 runner 检测到序号/hash 不匹配时，只能请求新 keyframe。
- 静态 legend、动作位定义和 DSL 语法放入可缓存的固定前缀，不在每次请求重复。
- 编码器必须设置硬字节上限和 token 预算；超限时发送 keyframe 摘要并标记 `truncated=1`，不得静默丢字段。

### 4.2 示例

```text
K v=1 q=40 f=1200 h=8ab2 size=32x30
sh a0=00000018183c3c18 a1=ffffffff00000000
bg .12,a1x6,.14/...省略空行RLE...
sp 03@10,12:a0,p1;07@18,12:a2,p2,fx
rs y0:scroll=0,0;y4:scroll=24,0

D v=1 q=41 base=40 f=1208 h=39d1
bg 19,12=a1
sp 03:+2,0;07:-1,0
ev scroll:+8,0
```

最终 DSL 不能仅凭人工观感确定；阶段 0 必须比较 JSON、紧凑文本、RLE 和稀疏坐标在目标 tokenizer 下的成本与模型正确率。

### 4.3 强制 keyframe 条件

- episode 开始、RESET、死亡或进入新场景；
- raster/scroll/pattern/palette 大幅变化；
- delta 预计 token 数超过 keyframe 的 50%；
- 距上次 keyframe 达到配置阈值；
- worker/模型报告 base sequence 或 state hash 不匹配；
- 请求失败后恢复、人工接管结束或 profile 切换。

## 5. 组合动作协议

现有 `Actions` 是稳定的 16-bit 系统无关位集，适合作为模型动作 ABI：

| bit | 语义 |
| ---: | --- |
| 0..3 | up、down、left、right |
| 4..7 | primary_1..primary_4 |
| 8..11 | select、start、coin、pause |

首期响应采用替换语义，避免增量 `set/clear` 在异常时留下卡键：

```text
A q=41 p1=0018 n=12
```

含义：以 `0x0018` 完整替换 P1 当前 AI 动作，保持 12 个模拟帧；到期自动变为 `0x0000`。组合键天然由多个 bit 同时置位表示。

约束：

- `n` 范围初定 `1..60`；模型超时、解析失败、暂停、退出、人工接管时立即清零。
- 每个系统 profile 声明 supported mask、互斥组合和端口数。
- 默认拒绝 `left+right`、`up+down`；需要相反方向同按的游戏必须显式开启。
- Start、Select、Coin、Pause 默认不向模型开放，由 CLI/profile 显式授权。
- 预留 `p2`，但第一期只执行 P1。
- 响应只接受单行动作 DSL 或严格 schema，不解析模型解释性文本。

## 6. 决策时钟与运行模式

### 6.1 第一阶段：同步 step-and-decide

```text
推进到决策边界
  -> 冻结观察
  -> 暂停模拟
  -> 请求 oMLX
  -> 校验动作
  -> 执行 n 帧
  -> 下一次观察
```

优点是观察不会在推理期间过期，回放只依赖 observation/action trace。此模式不承诺真实时间运行，但适合验证模型是否真正理解通用文本观察。

### 6.2 后续阶段：异步实时

只有同步模式通过后才引入：

- 单个 in-flight 请求和零长度等待队列；
- observation sequence、plan epoch 和最晚生效帧；
- 迟到结果丢弃；
- 本地低层控制器在 60 Hz 执行动作，模型低频规划；
- 落地、碰撞、死亡和场景切换事件可提前中断动作窗口。

不得通过减慢 CPU/PPU 时钟掩盖模型延迟。

## 7. oMLX 接入契约

CLI 计划：

```sh
zigarcade ai nes <rom.nes> \
  --endpoint http://127.0.0.1:8000/v1 \
  --model <exact-model-id> \
  --decision-frames 12 \
  --renderer auto
```

安全与协议要求：

- endpoint 只接受 `127.0.0.1` 或 `[::1]`，禁止重定向、代理、userinfo、query 和 fragment。
- `ZIGARCADE_OMLX_API_KEY` 是唯一 token 来源。
- 启动时通过 `GET /v1/models` 校验精确模型 ID。
- 使用非流式 chat completion；`temperature=0`，输出 token 上限尽可能低。
- 请求和响应都有字节上限、连接超时和总超时。
- HTTP worker 只拥有不可变 `ObservationPacket`，不得读取模拟器、Frame、TTY 或控制器。
- 日志只记录 sequence、token 数、延迟、动作和本地错误枚举，不记录 Authorization 或完整模型文本。

## 8. 计划模块与依赖

```text
src/ai/
  observation.zig       公共观察类型、canonical 编码、状态哈希
  text_codec.zig        keyframe/delta DSL 与 token 预算接口
  action_plan.zig       组合动作校验、持续时间、自动释放
  runner.zig            同步决策循环、人工覆盖、trace
  omlx_client.zig       loopback OpenAI 兼容 HTTP 客户端
  profile.zig           GameProfile 接口与 SHA-256 注册表
  adapters/smb1.zig     后续示例 profile

src/ai/nes/
  snapshot.zig          只读 presentation snapshot
  scene.zig             scroll/raster 后的可见背景和 OAM 场景
  shape_dict.zig        pattern 内容身份与 episode-local alias
  delta.zig             keyframe 比较与变化集
  inference.zig         后续自动实体/可控对象推断
```

依赖方向固定为：

```text
main -> ai, frontend, systems
ai/nes -> ai, core, systems/nes 的只读接口
ai/omlx_client -> ai（不得依赖 systems）
systems -> core（不得依赖 ai、HTTP 或文件系统）
```

## 9. 分阶段执行计划

### 阶段 0：协议样本与 token 基线

交付：

- 用合成 tile/OAM/raster 数据制作不含 ROM 资产的观察样本。
- 比较 JSON、紧凑 DSL、RLE、稀疏坐标的 token 数。
- 固定 Observation v1、Action v1 和 canonical 编码草案。
- 建立请求延迟测量脚本/测试夹具，但不连接真实游戏循环。

门槛：

- keyframe、稀疏 delta、密集 delta 都有 token 报告。
- 选定编码能被目标文本模型稳定解析，动作格式成功率达到 100% 的受控样本测试。
- 明确 keyframe/delta 切换阈值和最大上下文预算。

### 阶段 1：只读 NES PresentationSnapshot

交付：

- 在帧边界复制 presentation scroll/OAM/pattern/palette/raster 状态。
- 暴露 mapper 可见身份和 ROM SHA-256，不暴露可写 PPU。
- 固定缓冲区，无每帧堆分配，无副作用寄存器读取。

门槛：

- 快照不改变既有 CPU/PPU/framebuffer hash。
- live OAM 与 presentation OAM 不一致时，观察选择 presentation OAM。
- 分屏、滚动、CHR bank、palette 和 mirroring 变化都有合成单测。

### 阶段 2：通用场景、shape 字典和 delta

交付：

- 从 snapshot 重建实际可见背景 cell 和 sprite 列表。
- pattern 内容哈希、短 alias、首次字典发布。
- keyframe/delta 生成器、sequence/base/hash 校验和重同步；每个 keyframe 重置 episode shape alias，字典满载时强制请求新的 keyframe。
- headless `observe` 命令，只输出文本观察，不调用模型。

门槛：

- keyframe 加全部 delta 可逐步重建与每个帧边界相同的场景状态。
- 同一 ROM、同一输入回放得到相同 observation hash。
- 不同 CHR bank 的同 tile ID 不会错误复用 shape alias。
- 多个公开许可测试 ROM 和用户本地 ROM 均可输出通用观察，不需要 profile。

### 阶段 3：动作计划与确定性回放

交付：

- `mask + frames` 组合动作解析和系统约束。
- P1 注入、到期自动释放、人工输入优先、暂停和退出清零。
- `DecisionTrace` 记录 observation sequence、动作、生效帧和结果 hash。
- 无模型的脚本动作源，用于测试组合键和回放。

门槛：

- `right+A` 等组合在每个目标帧精确出现。
- 非法相反方向、越界持续时间、未知 bit 和迟到动作被拒绝。
- 相同 trace 产生相同输入日志和 framebuffer hash。

### 阶段 4：oMLX 同步文本 Agent

交付：

- loopback HTTP 客户端、模型发现、严格响应解析和超时。
- `ai nes` 同步 step-and-decide runner。
- 可选终端渲染和 headless 模式。
- 决策日志：输入 token、输出 token、TTFT、总延迟、动作和错误枚举。

门槛：

- HTTP mock 覆盖认证、错误状态、截断响应、重复字段、超时和超大 body。
- 推理失败立即释放输入，模拟器和终端正常退出。
- 模型在合成场景任务中能根据通用观察选择组合动作。
- 实机 ROM 验收只保存 hash、动作和指标，不提交资产。

### 阶段 5：Profile 与保守自动推断

交付：

- GameProfile 接口和精确 ROM hash 注册。
- SMB1 示例 profile，仅使用有证据的 RAM 字段。
- 视觉实体聚合、可控对象候选和置信度接口。
- 通用事实、推断事实、profile 确定事实在协议中分区。

门槛：

- 未知 hash 绝不启用 SMB profile。
- 关闭 profile 后仍能运行同一 ROM。
- 推断错误不会覆盖通用原始视觉事实。
- profile 单测只使用合成 RAM/OAM/PPU 夹具。

### 阶段 6：异步实时与经验复用（后续独立评审）

候选范围：

- 异步请求、动作 horizon、本地低层控制器；
- 事件驱动的提前重规划；
- 按 ROM 隔离的经验索引；
- save state、长期训练、完整 TUI；
- Neo Geo 等其他系统的 ObservationAdapter。

进入本阶段前必须重新评审确定性、安全、存储、过期动作和状态序列化，不能沿用首期同步假设直接开发。

## 10. 测试与指标

### 10.1 正确性测试

- snapshot 无副作用和 framebuffer hash 不变；
- raster 分屏、scroll、mirroring、CHR bank、palette、8x16 sprite、flip 和优先级；
- shape alias 稳定性与碰撞复核；
- keyframe/delta 重建、乱序、丢包、hash 不匹配和强制重同步；
- 双键/多键组合、互斥方向、自动释放、人工接管；
- ROM hash/profile 隔离；
- HTTP parser、大小限制、超时和敏感信息日志检查。

### 10.2 ROM 兼容性矩阵

通用观察验收至少覆盖现有支持的 Mapper 0/1/2/3/4/7，各选公开许可测试 ROM、自制 ROM 或用户本地合法 ROM。矩阵记录：

```text
ROM hash | mapper | raster/scroll | CHR-ROM/RAM | keyframe tokens |
delta p50/p95 | shape count | resync count | observation errors
```

“能输出观察”与“模型能游玩”分开统计，禁止用少数已知游戏的成功推导所有 ROM 可玩。

### 10.3 性能预算（阶段 0 后锁定）

初始目标，不作为未经测量的承诺：

- snapshot + 场景生成：ReleaseFast 下小于 1 ms/决策；
- 普通 delta：目标 20–100 tokens；
- keyframe：目标 200–800 tokens；
- 动作响应：不超过 12 个有效输出 tokens；
- 模拟帧循环在未启用 AI 时无可测回归；
- AI 编码使用调用方缓冲区，稳定运行不做每决策堆分配。

## 11. 风险与决策门

| 风险 | 处理 |
| --- | --- |
| 文本模型无法从视觉 alias 推断玩法 | 保留原始视觉事实；以 profile 提升重点 ROM；不夸大通用能力。 |
| tile ID 因 CHR bank 改变语义 | 使用 pattern 内容 shape_id，tile ID 仅作调试。 |
| OAM 多 sprite 组成一个对象 | 通用层保留原始 OAM；聚合仅作带置信度的推断。 |
| delta 造成上下文漂移 | sequence/base/hash、周期 keyframe、显式重同步。 |
| 紧凑字符串反而消耗更多 token | 使用真实 tokenizer 基准选择编码。 |
| 模型响应比动作窗口慢 | 首期暂停模拟；异步实时独立评审。 |
| 模型输出导致卡键 | 替换语义、持续帧上限、所有异常自动清零。 |
| 游戏逻辑不可从画面推断 | 通用层不声称语义；ROM profile 按 SHA-256 精确匹配。 |
| AI 改动污染模拟器核心 | 只读 snapshot 边界和单向依赖，核心不导入 AI/HTTP。 |

## 12. 完成定义

首期完成必须同时满足：

1. 任意当前受支持 NES ROM 可在无 profile 下生成版本化文本观察。
2. 观察 keyframe/delta 可重建、可 hash、可通过输入回放复现。
3. 文本模型可返回包含组合键的受限动作，动作能按精确帧数执行并自动释放。
4. oMLX 失败、模型输出错误、人工接管和退出均不会留下按键或后台 worker。
5. 目标模型的 token 与延迟报告已落盘，结论基于数据而非字符数估算。
6. 普通 `nes`、`framehash`、`romtest` 和终端输入/渲染行为无回归。

本计划批准后从阶段 0 开始；不得跳过协议/token 基线直接把模型 HTTP 调用塞入现有 NES 交互循环。
