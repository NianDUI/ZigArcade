# 参考资料与代码复用政策

ZigArcade 的源码采用 [MIT License](LICENSE)。本项目只独立实现代码；本文件记录用于行为比对、架构研究或测试研究的资料，不代表把其代码、ROM、BIOS 或测试资产纳入本仓库。

| 项目/资料 | URL | 计划用途 | 代码复用政策 |
|---|---|---|---|
| Mesen 2 | https://github.com/SourMesen/Mesen2 | NES PPU/NMI/mapper 行为与调试思路 | 禁止复制代码；实施前锁定 tag/commit 与许可证 |
| FCEUX | https://github.com/TASEmulators/fceux | NES CPU/mapper/trace 对照 | 禁止复制 GPL 代码 |
| Nestopia UE | https://github.com/0ldsk00l/nestopia | iNES 与 mapper 行为参照 | 禁止复制代码，实施前核对许可证 |
| NESdev Wiki | https://www.nesdev.org/wiki/ | 硬件寄存器、时序资料 | 记录具体页面与许可/署名要求 |
| FinalBurn Neo | https://github.com/finalburnneo/FBNeo | Neo Geo ROM/video/audio 的架构研究 | 禁止复制代码；逐版本核对许可证与非商业条款 |
| GnGeo | https://github.com/MatChung/gngeo | Neo Geo 系统边界研究 | 禁止复制代码，实施前核对许可证 |
| Ghostty | https://github.com/ghostty-org/ghostty | Kitty 图形协议行为与资源管理参照 | 仅独立生成 APC 协议序列，不复制实现 |

## 已锁定的 Neo Geo 地址图资料

| 资料 | 固定版本 | 研究模块 | 使用边界 |
|---|---|---|---|
| NeoGeo Development Wiki：`68k memory map` | revision 8317，2026-08-13 访问 | 卡带 68000 地址范围、镜像、物理大小 | 页面标注 CC0；只记录硬件事实，未导入资产或代码 |
| NeoGeo Development Wiki：`Memory mapped registers` | revision 9288，2026-08-13 访问 | I/O 基址、decode mask、LSPC/video 与 system-control 语义 | 页面明确部分 decode mask 未验证；实现前须有独立测试或第二来源核验 |
| NeoGeo Development Wiki：`68k/Z80 communication` | revision 5271，2026-08-14 访问 | `REG_SOUND` 的命令/回复 latch 与 Z80 NMI 条件 | 页面标注 CC0；仅实现 latch 行为，不复制示例代码或引入 Z80 实现 |
| MAME `src/mame/snk/neogeo.cpp` / `neogeo_v.cpp` | `c8f7357b5c573fd7f236c4747f0f34fafe510c54`，2026-08-13、2026-08-14 访问 | MVS/AES 主地址图、`$000000-$00007F` BIOS/P-ROM vector 切换范围、标准 `$2FFFF0-$2FFFFF` P-ROM bank-select、MVS backup-RAM write-enable latch 及双 palette-RAM bank 的 CPU-visible 选择 | 文件头 SPDX `BSD-3-Clause`（可与 MIT 共存）；本项目仍只作行为研究，严禁复制代码 |
| FBNeo `src/burn/drv/neogeo/neo_run.cpp` | `2fcb2628fbfd529806e75f3559a9d82758c8a5cc`，2026-08-13 访问 | 与 MAME/Wiki 的地址译码交叉核验 | 含非商业与公开修改等限制；严禁复制代码或资产 |

每次实际采用一项外部资料时，都必须补充锁定的 commit/tag、许可证/SPDX、研究模块与日期。许可不明或与 MIT 发布策略不兼容时，不得拷贝其代码或提交其资产。
