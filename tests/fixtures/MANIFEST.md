# 测试资产清单

每项未来资产必须记录：

| 名称 | URL | 锁定版本/commit | SHA-256 | 许可证/SPDX | 测试命令 | 期望状态码/帧数 |
|---|---|---|---|---|---|---|
| `nes15-NTSC.nes` | https://github.com/christopherpow/nes-test-roms | `95d8f621ae55cee0d09b91519a8989ae0e64753b`，`nes15-1.0.0/nes15-NTSC.nes` | `01b0507abdee44e6b78edcbe95f1de951c9d7ec39e7fcc5306f5e06b732ef92c` | BSD-2-Clause | `zig build test` | 运行 3 帧，Wyhash=`8264638174104152342` |

仅在资产明确允许再分发时，才可提交到本仓库。商业 ROM、Neo Geo BIOS、密钥和任何来源不明资产不得提交。

Neo Geo 的本地测试记录还必须按 `P/C/S/M/V/BIOS` 区域分别列出条目、大小、SHA-256、byte/word endian、interleave 与 continuation/reload 规则；这些条目可以只作为用户本地 manifest，不代表允许把原始资产提交至仓库。
