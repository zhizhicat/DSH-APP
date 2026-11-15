# rc.2 实验引擎攻坚状态（2026-11-15 收官）

## 当前线上状态
- layers-index.json：4 底座（debian-12/13、ubuntu-24.04.5/26.04.1）+ engine 双版本（0.2.2-rc.1、0.2.2-rc.2）+ 3 node ✓
- rc.2 engine = 实验版：102 补丁成功 + 30 N/A
- 缺口（N/A）：direct 直连加速（zz-direct-runtime，8 包 seam 需按 rc.2 重构重实现）、mobile newline（上游 client-ui 改 ModuleLoader 压缩发布且丢分支）、session-deletion（13 包重构）、title-cache、atomic 系列、terminal-job-cancel、provider-discovery-headers 等

## 已修基础设施（永久资产）
1. patch-dsh：pin:false 显式 N/A + record 增量落盘 + record 模式 sha 链识别已打补丁文件
2. 3 个结构适配补丁：install-log-redaction-expected / plugin-manager-cancel-tree-expected / zzz-config-editor-path-expected
3. layers.yml merge 步骤（深层合并，防部分变体覆盖 index）——deep-merge bug 已修（组内版本键合并）
4. tooling/merge-layers-index.py 深合并版

## 关键教训（防复发）
- npmmirror/npm pack 存在同名 tgz 幽灵内容（/tmp 残留+CDN 漂移）——本地验证必须以 CI 真实安装树为准
- record 全绿才落盘 = 中途失败全丢 → 已改增量落盘
- sweep 批量 N/A 有误杀风险（重跑时已打补丁重复套用失败被误标）——误杀补丁后续可恢复重打
- GitHub release asset 更新有 CDN 传播延迟——验证用 API asset id 直读

## 下一步（用户侧）
1. 手机下载页 DSH 下拉应出现 0.2.2-rc.1/0.2.2-rc.2 → 选 rc.2 热更（只下 engine 层）
2. 实测：UI 能否加载 ModuleLoader 压缩包、会话能否跑、普通回车行为（预期直接发送=上游回归）
3. 若不可用→App 内切回 rc.1 即可（rc.1 层未动）

## 待办
- [ ] 实测反馈后定去留
- [ ] 误杀补丁恢复重打（待实验版验证通过后精修）
- [ ] 给上游提 issue：mobile newline 回归 + minified 发布对二开影响
