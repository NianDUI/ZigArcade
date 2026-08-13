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

每次实际采用一项外部资料时，都必须补充锁定的 commit/tag、许可证/SPDX、研究模块与日期。许可不明或与 MIT 发布策略不兼容时，不得拷贝其代码或提交其资产。
