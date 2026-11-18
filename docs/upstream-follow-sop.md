# DSH 上游跟随 SOP（适配层重发）

> 2026-11-19 立档 · 小栀栀 · 拍板：栀栀
> 前提：纯净版双轨与装机期 npm 组装已撤（同日拍板），上游跟随唯一定义为
> **"上游新版本 → 154 补丁照打 → 出适配层"**。不装机期拼装、不发无补丁层。

## 触发

栀栀说「**上游更新了**」/「DSH 上游更新了」/「去适配 rc.X」时启动本流程。

## 流程（七步，全程 API 实查不读页面）

### 1. 查官方最新版

```bash
# npm dist-tags（官方发版先动这里，latest 可能滞后于 next）
curl -s https://registry.npmjs.org/@deepseek-ai/dsh | jq .dist-tags
# GitHub tag（佐证）
curl -s -H "Authorization: token $TOKEN" \
  https://api.github.com/repos/deepseek-ai/deepseek-harness/releases?per_page=3 | jq '.[].tag_name'
```

基线参考（2026-11-19 查证）：npm latest=0.2.2-rc.1 / next=0.2.2-rc.5；GitHub tag 走到 dsh-v0.2.2-rc.5，release assets 恒空（官方只发源码，npm 是唯一产物渠道）。

### 2. 调查上游变更

```bash
# 版本间包级 diff（packument versions diff）
# GitHub 源码 diff（quilt 补丁关心的文件）
curl -s -H "Authorization: token $TOKEN" \
  https://api.github.com/repos/deepseek-ai/deepseek-harness/compare/dsh-v<旧>...dsh-v<新> | jq '.files[].filename'
```

输出一份「上游动了哪些包/文件」清单，与我们的补丁目标文件求交集——**交集非空的补丁是本轮 rebase 的工作量**。

### 3. 补丁 rebase

- 补丁库：`runtime/patches/`，quilt 式：`series`（154 个活跃补丁，按序应用）+ `pins.json`（补丁×版本×文件的 before/after sha256 链）
- **上游没动目标文件的补丁**：pins.json 登记新版本的 before（=旧 after）后直接干净 apply
- **上游动了目标文件的**：人工核对 diff，改写补丁头（.diff 文件）使其在新树上 apply，重算 after 哈希
- 校验工具：`runtime/build-runtime.sh` 调 `patch-dsh`（`--target android --prefix ... --dsh-version ... --patches runtime/patches --out dsh-patches.json`），补丁打不上会 fail

### 4. pins.json 登记新版本

每个补丁的 `pins.json` 条目加 `"<新版本>"` 块（before/after 哈希），旧版本条目保留（回滚用）。

### 5. CI 出适配层

`layers.yml` workflow_dispatch，指定 `DSH_VERSION=<新版本>`——build-runtime.sh 恒走补丁链（DSH_PURE 通道已删，2026-11-19）。产物：`engine-dsh<版本>-arm64-v8a.tar.xz` 上 `runtime-layers` release，index 由 merge-layers-index.py 合并（compose 块深合并勿回退——2026-11-19 事故教训已锁回归测试）。

### 6. 出 APK（如有 App 侧联动改动）

`apk.yml` workflow_dispatch 出 v3rN 包。

### 7. 交付装机验证

send_file APK → 栀栀装机实测：装新引擎层 → 跑一轮 DSH 会话（phone 通道/companion/附件三个 C 类大户各试一发射线）→ 绿了才算完成。装机验证算栀栀的，出问题三板凳定位（诊断包 versionCode → engine.log 版本串 → 读代码）。

## 责任与纪律

- **rc 小版本**：通常大半补丁干净 apply，半小时级
- **上游重构**：某包大改就是重活，如实报工作量，不硬扛不藏
- **跟版本绑死的持续责任**：补丁不是一次性的，每版上游更新都要过一遍交集
- 官方源优先级：npm packument（产物权威）> GitHub tag（源码权威）；**不得**以「tag 有 source tar.gz」为由走源码路线（那是开发者快照，无 node_modules 无 dist，装机不可用——2026-11-19 实测 42.9MB/24003 文件/node_modules 0）
