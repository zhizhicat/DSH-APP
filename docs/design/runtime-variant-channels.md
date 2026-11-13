# Runtime Variant Channels（档二：下载源与版本选择）

日期：2026-11-13 ｜ 状态：实施中 ｜ 拍板：栀栀 2026-11-13 08:36

## 需求（用户原话归纳）

引导流「选择外观」页之前，供用户：

1. 选择下载源（ghfast.top / gh-proxy.com / GitHub 直连…），带连接性探测
2. 选择 rootfs 版本（Ubuntu 24.04.5 / 26.04.1；Debian 12/13 后推）
3. 选择 node 版本（24.9.0 / 24.22.1 / 24.x / 26.x）
4. 选择 DSH 上游版本（0.2.2-rc.1 / …）
5. 下载后由 App 解压合并（base → node → engine 顺序叠加）

## 架构决策

### 三层拆分（组合爆炸的解法）

上游 `ENGINE_PATHS` 把 node+dsh 绑在 engine 层。拆成：

- **NODE_PATHS**：`opt/node` + `usr/local/bin/{node,npm,npx,corepack}`
- **ENGINE_PATHS**（改后）：`opt/dsh`、`opt/dsh-go`、`etc/dsh-app`、`etc/profile.d/dsh-app.sh`、`usr/local/lib/node_modules/pnpm` + `usr/local/bin/{dsh,pnpm,pnpx,pn,pnx}`（pnpm 归 engine：版本由 DSH repo pin 决定）

包数 = base数 + node数 + engine数，覆盖全部组合。

### 关键洞察（零新安装机制）

`RuntimeManifest.archives` 是通用列表，`RuntimeInstaller.install()` 已 for 循环顺序解压到同一 staging（后层覆盖前层同名文件 = tar 天然合并）。App 侧只需**构造** archives=[base,node,engine] 的 RuntimeManifest，安装/解压/进度/通知全复用。

### 通道目录 schema 3（channels.json + 目录 manifest）

assets/channels.json（App 内置）：

```json
{
  "schema": 3,
  "default": "dsh-go-layers",
  "sources": [
    {"id": "ghfast", "name": "ghfast.top 国内加速", "prefix": "https://ghfast.top/"},
    {"id": "ghproxy", "name": "gh-proxy.com 国内加速", "prefix": "https://gh-proxy.com/"},
    {"id": "github", "name": "GitHub 直连", "prefix": ""}
  ],
  "githubBase": "https://github.com/zhizhicat/DSH-APP/releases/download/runtime-layers/",
  "channels": [
    {"id": "dsh-go-layers", "name": "DSH Go 三层通道", "index": "index.json", "sha256": "<index.json 的 sha256>"}
  ]
}
```

远端 index.json（一次拉取，本地选变体）：

```json
{
  "schema": 3,
  "abi": "arm64-v8a",
  "bases": {"ubuntu-24.04.5": {"asset": "base-ubuntu-24.04.5-arm64-v8a.tar.xz", "bytes": 0, "sha256": "", "uncompressedBytes": 0}},
  "nodes": {"24.22.1": {}},
  "engines": {"0.2.2-rc.1": {}},
  "defaults": {"base": "ubuntu-24.04.5", "node": "24.22.1", "engine": "0.2.2-rc.1"},
  "launch": {"argv": [], "env": {}}
}
```

URL 拼装：`source.prefix + githubBase + asset`（prefix 空 = GitHub 直连）。

### Kotlin 改动面

- `ChannelRegistry`：v3 解析（sources + channels[].index），v1 兼容保留
- `RuntimePlugin` 新 methodChannel：
  - `probeSources`：对每 source 发 4KB Range 请求（HttpURLConnection），返回 {id, ok, ms}
  - `channelIndex`：拉+sha256 校验 index.json
  - `installChannel` 扩展参数：`{id, sourceId, base, node, engine}` → 构造三层 archives 的 RuntimeManifest → 现有下载解压
- `RuntimeManifest`：加程序化构造路径（不经 fromJson 的 asset 命名校验）

### Flutter 改动面

- 新页 `download_source_step.dart`：源列表（探测转圈/延迟绿红）+ 三个变体选择 + 预计下载量 + 开始下载
- `onboarding_flow.dart`：OnboardingStep 插 `downloadSource`（runtime 选本机后、appearance 前；远程跳过）
- 偏好存储：SharedPreferences
- l10n：en + zh 双语
- `setup_progress.dart` `_installFromChannel`：noruntime 首装走用户选择

### CI（runtime-layers release）

build-runtime.sh 新模式 `RUNTIME_LAYERS=3`（三层）+ 变体循环：

- base：UBUNTU_VERSION ∈ {24.04.5, 26.04.1}（Debian 12/13 后推）
- node：NODE_VERSION ∈ {24.9.0, 24.22.1, 26.x}
- engine：DSH_VERSION ∈ {0.2.2-rc.1}
- 产物：`runtime-layers` tag release：所有层包 + index.json；CI 后人工验证再回填 channels.json 的 index sha256

## 分期

- **本轮**：三层拆分 + 源选择探测 UI + Ubuntu 24/26 + node 3 版 + dsh 0.2.2-rc.1
- **后推一**：Debian 12/13 base
- **后推二（档三）**：dsh 装机后动态换版本

## 风险与对策

- node×base glibc：node 24 需 ≥2.28，Ubuntu 24/26 均满足；26.04 debs 锁不齐则先只出 24.04.5
- index.json sha256 回填：CI 产出后人工验证再提交
- 变体兼容性：目录只放已验证组合，UI 不做强校验
