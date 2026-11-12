# DSH APP

> ⚠️ **占位仓库名与占位项目名**——正式名称待定，命名不影响代码与许可。

DSH 安卓客户端的 **noruntime 二开版**：APK 瘦身、运行时（rootfs / Node）从包内内置改为按需下载与替换，增加源池选择。

## 项目出处与产权边界

| 项 | 说明 |
|---|---|
| 二开自 | [ccch1mneyyy/dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) |
| 上游许可 | **AGPL-3.0** |
| 本仓库许可 | **AGPL-3.0**（继承上游，所有修改同以 AGPL-3.0 发布） |
| 原始 README | 上游原文完整保留于 [README.upstream.md](README.upstream.md) |
| 版权归属 | 原始版权与署名权归上游作者 ccch1mneyyy 所有；本仓库不声称对上游原创部分持有任何权利 |

依据 AGPL-3.0 要求：本仓库为上游的修改版，已随源码附上许可证副本（`LICENSE`），并标注上游来源与修改说明。

## 与上游的差异（进行中）

- [ ] 移除 APK 内置 rootfs / Node 运行时包（瘦身）
- [ ] 首启引导下载运行时，sha256 + 官方 SUMS 双校验
- [ ] 运行时**替换制**：Ubuntu 24.04.5 / 26.04.1、Debian 12 / 13 可选通道，同一时刻仅一套在机
- [ ] Node 版本槽：24.9.0（最低）/ 24.22.2（默认）/ 24 线最新 / 26 线（需 rootfs 内 libatomic1）
- [ ] 源池：TUNA（ubuntu-cdimage + lxc-images）与 npmmirror

其余功能与上游保持一致，构建方式见 [README.upstream.md](README.upstream.md)。

## 容器层组件声明

proot 与 tawcroot（源自 [wmww/tawc](https://github.com/wmww/tawc)，GPL-3.0）均为上游已有依赖，本仓库沿用其上游 pin，不做修改。
