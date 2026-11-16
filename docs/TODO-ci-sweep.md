
## 2026-11-16 10:45 上午增量（tavern 专档立项材料）
- 上游 v1.1.0 后 main 又推进 56 提交（80c53460e），含：golden 重生成(466d0bdee)、确认弹窗三档授权(66f1dc416)、chat 插话快照修复(492c5c2ab)、runtime --target android 修复(Pro 5620,不影响我们——我们 rtbuild 无此参数)
- 17 个 Flutter failed 归因：6 golden(76899f35 已修)+11 workshop/tavern(上游 56 提交里大概率有答案)
- guide lint 账：群聊 UI label(New group chat/Who's in it 等)在 arb 不存在——上游 merge 时 l10n parts 没带全或文档超前，归 tavern 专档
- **tavern 专档主策略：merge upstream/main(56 提交)**，顺带带走 golden/测试修复；注意上次 merge v1.1.0 出 1949 错的教训——冲突解干净+merge 后全量跑三道检查
- 待验证：76899f35 CI(goldens+Runtime locks 优先版首验)
