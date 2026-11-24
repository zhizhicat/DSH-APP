// Variant channels (schema 3), before 选择外观 on a noruntime first run:
// pick base / node / engine versions from the layers index, then pick a
// mirror for each. 纯自选：不替用户预选任何版本或源——选了版本才渲染该层
// 源并自动探测一轮；换版本重渲染重探测；手动换源即时测一次。
// 开始下载 hands over to the usual unpack flow.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import 'onboarding_scaffold.dart';

/// Mirror reachability for one source, filled by a 1-byte range probe.
class _ProbeState {
  const _ProbeState({this.pending = true, this.latencyMs, this.ok = false});
  final bool pending;
  final int? latencyMs;
  final bool ok;
  _ProbeState withResult({required bool ok, required int latencyMs}) =>
      _ProbeState(pending: false, latencyMs: latencyMs, ok: ok);
}

class DownloadSourceStepPage extends ConsumerStatefulWidget {
  const DownloadSourceStepPage({super.key, required this.onDone, this.onDefault});

  /// Called with the chosen source id + layers choice when 开始下载 is tapped.
  final void Function(String sourceId, LayersChoice choice) onDone;

  /// 「用默认通道下载」 when no mirror can serve the index: the caller starts
  /// the flat-channel unpack instead. Null hides the escape hatch.
  final VoidCallback? onDefault;

  @override
  ConsumerState<DownloadSourceStepPage> createState() => _DownloadSourceStepPageState();
}

class _DownloadSourceStepPageState extends ConsumerState<DownloadSourceStepPage> {
  List<RuntimeSourceInfo> _sources = const [];
  Map<String, List<RuntimeSourceInfo>> _layerSources = const {};
  final _layerProbes = <String, _ProbeState>{};
  String? _layerChannelId;
  LayersIndex? _index;
  bool _indexLoading = false;
  String? _indexError;

  // 内部取 index 用的源（含故障转移）。只有 _basePicked 后它才同时是
  // 用户选定的底座源，否则不参与高亮与落盘。
  String? _sourceId;
  bool _basePicked = false;

  // 纯自选：三层版本与 node/engine 源都由用户手选，初始全空。
  String? _baseKey;
  String? _nodeKey;
  String? _engineKey;
  String? _nodeSourceId;
  String? _engineSourceId;

  // 恢复 B：二次进入还原用户上次自己选的组合（不替选）。
  LayersChoice? _savedChoice;
  String? _savedBaseSourceId;

  String? _layerKeyOf(String layer) => switch (layer) {
        'base' => _baseKey,
        'node' => _nodeKey,
        'engine' => _engineKey,
        _ => null,
      };

  /// 三层版本 + 三层源全选齐才算就绪（MB 行与开始下载共用）。
  bool get _allReady =>
      _choice != null &&
      _sourceId != null &&
      _basePicked &&
      _nodeSourceId != null &&
      _engineSourceId != null;

  LayersChoice? get _choice {
    final b = _baseKey, n = _nodeKey, e = _engineKey;
    if (b == null || n == null || e == null) return null;
    return LayersChoice(base: b, node: n, engine: e);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final runtime = ref.read(localRuntimeProvider.notifier);
    final sources = await runtime.channelSources();
    Map<String, List<RuntimeSourceInfo>> layerSources = const {};
    try {
      layerSources = await runtime.layerSources();
    } catch (_) {/* 三层源池是 v1.5 新桥：旧原生回退到单源池 */}
    final channelId = await _layerChannel();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _layerSources = layerSources;
    });
    final saved = await LocalRuntimeController.loadVariantPrefs();
    _savedChoice = saved.choice;
    _savedBaseSourceId =
        _sources.any((s) => s.id == saved.sourceId) ? saved.sourceId : null;
    // 只还原用户上次自己选的（B），不做任何 fallback 预选。
    _nodeSourceId = _validLayerSource('node', saved.nodeSourceId);
    _engineSourceId = _validLayerSource('engine', saved.engineSourceId);
    // 初始 index 的源：已保存的用已保存的（用户的选择优先）；首次进入对
    // gh 四源并发探测竞速——第一个探通的立即用它拉 index（2026-11-22 拍板）。
    // 输了的源只探不拉，UI 源选择不受影响（_savePrefs 护栏：拉 index 的
    // 源不落盘、不伪装成用户选择）。
    if (_savedBaseSourceId != null && channelId != null) {
      unawaited(_selectSource(_savedBaseSourceId!, _savedChoice));
      return;
    }
    if (channelId != null && _sources.isNotEmpty) {
      unawaited(_raceIndexSource(channelId));
    }
  }

  /// 四路齐发探测（2026-11-22 拍板）：第一个探通的源立即用它拉 index，
  /// 其余在飞探测 native 侧直接掐断（真·disconnect）；全挂则按池序串行
  /// 兜底（_selectSource 既有故障转移，错误文案与旧行为一致）。
  Future<void> _raceIndexSource(String channelId) async {
    final fastest = await ref
        .read(localRuntimeProvider.notifier)
        .raceProbeSource(channelId, _sources);
    if (!mounted) return;
    await _selectSource(fastest ?? _sources.first.id, _savedChoice);
  }

  bool _reprobing = false;

  /// 重新探测已激活的层（选了版本的层）；index 拉不到时退化为重测底座池
  /// （给换源重试做参考）。保留选择,清旧结果让 chips 重新显示探测中。
  Future<void> _reprobeAll() async {
    if (_reprobing) return;
    final layers = _index == null
        ? const ['base']
        : ['base', 'node', 'engine'].where((l) => _layerKeyOf(l) != null).toList();
    if (layers.isEmpty) return;
    setState(() {
      _reprobing = true;
      for (final l in layers) {
        _layerProbes.removeWhere((k, v) => k.startsWith('$l:'));
      }
    });
    final futures = <Future<void>>[];
    for (final layer in layers) {
      final pool = layer == 'base'
          ? _basePool()
          : (_layerSources[layer] ?? const <RuntimeSourceInfo>[]);
      for (final src in pool) {
        futures.add(_probeLayer(layer, src.id,
            nodeVersion: layer == 'node' ? _nodeKey : null));
      }
    }
    await Future.wait(futures);
    if (mounted) setState(() => _reprobing = false);
  }

  /// 该 id 在此层池里有效则原样返回，否则 null。
  String? _validLayerSource(String layer, String? id) =>
      (id != null && (_layerSources[layer] ?? const []).any((s) => s.id == id)) ? id : null;

  Future<void> _probeLayer(String layer, String sourceId, {String? nodeVersion}) async {
    final channelId = await _layerChannel();
    if (channelId == null || !mounted) return;
    final result = await ref
        .read(localRuntimeProvider.notifier)
        .probeLayerSource(channelId, layer, sourceId, nodeVersion: nodeVersion);
    if (!mounted) return;
    setState(() {
      _layerProbes['$layer:$sourceId'] = (_layerProbes['$layer:$sourceId'] ?? const _ProbeState())
          .withResult(ok: result['ok'] == true, latencyMs: (result['latencyMs'] as num?)?.toInt() ?? -1);
    });
  }

  Future<String?> _layerChannel() async {
    final channelId = _layerChannelId;
    if (channelId != null) return channelId;
    final channels = await ref.read(localRuntimeProvider.notifier).channels();
    for (final c in channels) {
      if (c.id.contains('layers')) {
        _layerChannelId = c.id;
        break;
      }
    }
    return _layerChannelId;
  }

  /// 选源入口：失败时按剩余源自动故障转移（探测延迟低者优先，最多轮完）。
  /// 全源轮完仍失败：给底座 chips 补一轮探测，供换源重试参考。
  Future<void> _selectSource(String sourceId, LayersChoice? preferred) async {
    final tried = <String>{sourceId};
    var current = sourceId;
    while (true) {
      final failed = await _fetchIndexOnce(current, preferred);
      if (!failed) return;
      final next = _nextSourceAfter(current, tried);
      if (next == null) {
        if (mounted && _baseKey == null) _probeLayerOnce('base');
        return;
      }
      if (!mounted) return;
      tried.add(next);
      current = next;
      setState(() => _sourceId = next);
    }
  }

  String? _nextSourceAfter(String id, Set<String> tried) {
    final pool = _basePool();
    // 探测可用且延迟最低的未试源优先；没有探测结果时按池序。
    final candidates = pool.where((s) => !tried.contains(s.id)).toList()
      ..sort((a, b) {
        final pa = _layerProbes['base:${a.id}'], pb = _layerProbes['base:${b.id}'];
        final la = (pa != null && pa.ok) ? (pa.latencyMs ?? 9999) : 99999;
        final lb = (pb != null && pb.ok) ? (pb.latencyMs ?? 9999) : 99999;
        return la.compareTo(lb);
      });
    return candidates.isEmpty ? null : candidates.first.id;
  }

  /// 拉一次 index。成功时只恢复用户上次自己选的组合（B：不 defaultFor 替选），
  /// 并对恢复出的活跃层各探测一轮。
  Future<bool> _fetchIndexOnce(String sourceId, LayersChoice? preferred) async {
    setState(() {
      _sourceId = sourceId;
      _index = null;
      _indexError = null;
      _indexLoading = true;
    });
    final channelId = await _layerChannel();
    if (channelId == null) {
      if (!mounted) return true;
      // 旧原生层没有 probeLayerSource：整页退回「索引失败」样态（chips 全挂起）。
      setState(() {
        _indexLoading = false;
        _indexError = '${context.l10n.setupSourceIndexFailed}\nold runtime channel';
        _baseKey = _nodeKey = _engineKey = null;
        _basePicked = false;
      });
      return true;
    }
    Object? indexError;
    LayersIndex? index;
    try {
      index = await ref.read(localRuntimeProvider.notifier).layersIndex(channelId, sourceId);
    } catch (e) {
      indexError = e;
    }
    if (!mounted) return true;
    setState(() {
      _indexLoading = false;
      _index = index;
      if (index == null) {
        _indexError = '${context.l10n.setupSourceIndexFailed}\n$indexError';
        _baseKey = _nodeKey = _engineKey = null;
        _basePicked = false;
      } else {
        _indexError = null;
        final restored = _validChoice(preferred, index);
        _baseKey = restored?.base;
        _nodeKey = restored?.node;
        _engineKey = restored?.engine;
        // 恢复 B：上次自己选的底座源仍在当前池内才还原为已选。
        if (restored != null &&
            _savedBaseSourceId != null &&
            _basePool().any((s) => s.id == _savedBaseSourceId)) {
          _sourceId = _savedBaseSourceId;
          _basePicked = true;
        }
      }
    });
    if (index != null) {
      for (final layer in const ['base', 'node', 'engine']) {
        if (_layerKeyOf(layer) != null) _probeLayerOnce(layer);
      }
    }
    return index == null;
  }

  LayersChoice? _validChoice(LayersChoice? preferred, LayersIndex index) {
    if (preferred == null) return null;
    if (!index.base.any((v) => v.key == preferred.base)) return null;
    if (!index.node.any((v) => v.key == preferred.node)) return null;
    if (!index.engine.any((v) => v.key == preferred.engine)) return null;
    return preferred;
  }

  int get _totalBytes {
    final index = _index;
    final choice = _choice;
    if (index == null || choice == null) return 0;
    return index.base.firstWhere((v) => v.key == choice.base).bytes +
        index.node.firstWhere((v) => v.key == choice.node).bytes +
        index.engine.firstWhere((v) => v.key == choice.engine).bytes;
  }

  /// 底座源按所选底座过滤：原生源与底座一一对应——
  /// ubuntu → ubuntu-base（cdimage/ubuntu-cdimage 镜像直拉），
  /// debian → debian-base（debuerreotype rootfs，compose 镜像组指向本仓库
  /// release 的重发布资产）。跨底座显示会误导（2026-11-19 截图实锤：
  /// debian-12 + 高亮「Ubuntu 官方 cdimage」）且选错装机路。
  List<RuntimeSourceInfo> _basePool() {
    final pool = _layerSources['base'] ?? _sources;
    final base = _baseKey;
    if (base == null) return pool;
    if (base.startsWith('ubuntu-')) {
      return pool.where((s) => s.kind != 'debian-base').toList();
    }
    return pool.where((s) => s.kind != 'ubuntu-base').toList();
  }

  void _probeLayerOnce(String layer) {
    final pool = layer == 'base'
        ? _basePool()
        : (_layerSources[layer] ?? const <RuntimeSourceInfo>[]);
    final nodeVersion = layer == 'node' ? _nodeKey : null;
    for (final src in pool) {
      unawaited(_probeLayer(layer, src.id, nodeVersion: nodeVersion));
    }
  }

  /// 选版本：该层源重渲染 + 清旧探测重测一轮。base 跨族切换（ubuntu ↔
  /// debian）池子不同：已选底座源失效清空，重选。选完即落盘（就绪条件
  /// 齐了才真正写库），离开页面也能续回同一组合。
  void _pickVariant(String layer, String key) {
    setState(() {
      switch (layer) {
        case 'base':
          final old = _baseKey;
          _baseKey = key;
          if (old != null &&
              old.startsWith('ubuntu-') != key.startsWith('ubuntu-')) {
            _sourceId = null;
            _basePicked = false;
          }
        case 'node':
          _nodeKey = key;
        case 'engine':
          _engineKey = key;
      }
      _layerProbes.removeWhere((k, v) => k.startsWith('$layer:'));
    });
    _probeLayerOnce(layer);
    _savePrefs();
  }

  /// 手动选底座源：不再重拉 index（版本已在前）；即时探测该源一次。
  void _pickBaseSource(String id) {
    setState(() {
      _sourceId = id;
      _basePicked = true;
    });
    unawaited(_probeLayer('base', id));
    _savePrefs();
  }

  /// 手动换 node/engine 源：即时探测该源一次（node 探测带版本）。
  void _pickLayerSource(String layer, String id) {
    setState(() {
      switch (layer) {
        case 'node':
          _nodeSourceId = id;
        case 'engine':
          _engineSourceId = id;
      }
    });
    unawaited(_probeLayer(layer, id,
        nodeVersion: layer == 'node' ? _nodeKey : null));
    _savePrefs();
  }

  /// 只在用户真选过底座源时落盘：_sourceId 在那之前只是内部取 index 的
  /// 源，写进去会伪装成「用户选的」混进下次恢复链。
  void _savePrefs() {
    final choice = _choice;
    final sourceId = _sourceId;
    if (choice == null || sourceId == null || !_basePicked) return;
    unawaited(LocalRuntimeController.saveVariantPrefs(
      sourceId: sourceId,
      choice: choice,
      nodeSourceId: _nodeSourceId,
      engineSourceId: _engineSourceId,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return OnboardingScaffold(
      footer: Row(
        children: [
          OutlinedButton(
            onPressed: (_reprobing || _indexLoading) ? null : _reprobeAll,
            // 64 = 按钮类默认最小宽。不能用 Size.fromHeight(52)：
            // fromHeight 的宽是 infinity，在 Row（不约束宽）里就是
            // infinite width 布局错误，release 下断言剥掉后整个按钮静默消失。
            style: OutlinedButton.styleFrom(minimumSize: const Size(64, 52)),
            child: _reprobing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.setupSourceReprobe),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: _allReady
                  ? () async {
                      await LocalRuntimeController.saveVariantPrefs(
                        sourceId: _sourceId!,
                        choice: _choice!,
                        nodeSourceId: _nodeSourceId,
                        engineSourceId: _engineSourceId,
                      );
                      widget.onDone(_sourceId!, _choice!);
                    }
                  : null,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: Text(l10n.setupSourceStart),
            ),
          ),
        ],
      ),
      children: [
        const SizedBox(height: 8),
        OnboardingHeader(
          icon: AppIcons.download,
          title: l10n.setupSourceTitle,
          message: l10n.setupSourceMessage,
        ),
        // 构建标记：真机对版用（排"装的不是新包"的雷）。
        Text(
          'build v3r33',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        if (_indexError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_indexError!, style: Theme.of(context).textTheme.bodySmall),
          ),
        _LayerCard(
          key: const ValueKey('setup-layer-base'),
          label: l10n.setupSourceRootfs,
          variants: _index?.base ?? const [],
          selectedKey: _baseKey ?? '',
          onVariant: (k) => _pickVariant('base', k),
          // 版本选了才渲染源；index 拉挂时也亮底座源——留换源重试的口子。
          sources: (_baseKey != null || _indexError != null)
              ? _basePool()
              : const [],
          selectedSourceId: (_basePicked || _indexError != null) ? _sourceId : null,
          onSource: (_indexError != null && _baseKey == null)
              ? (id) => unawaited(_selectSource(id, _savedChoice))
              : _pickBaseSource,
          probes: _layerProbes,
          layer: 'base',
        ),
        const SizedBox(height: 12),
        _LayerCard(
          key: const ValueKey('setup-layer-node'),
          label: l10n.setupSourceNode,
          variants: _index?.node ?? const [],
          selectedKey: _nodeKey ?? '',
          onVariant: (k) => _pickVariant('node', k),
          sources: _nodeKey != null ? (_layerSources['node'] ?? const []) : const [],
          selectedSourceId: _nodeKey != null ? _nodeSourceId : null,
          onSource: (id) => _pickLayerSource('node', id),
          probes: _layerProbes,
          layer: 'node',
        ),
        const SizedBox(height: 12),
        _LayerCard(
          key: const ValueKey('setup-layer-engine'),
          label: l10n.setupSourceDsh,
          variants: _index?.engine ?? const [],
          selectedKey: _engineKey ?? '',
          onVariant: (k) => _pickVariant('engine', k),
          sources: _engineKey != null ? (_layerSources['engine'] ?? const []) : const [],
          selectedSourceId: _engineKey != null ? _engineSourceId : null,
          onSource: (id) => _pickLayerSource('engine', id),
          probes: _layerProbes,
          layer: 'engine',
        ),
        const SizedBox(height: 12),
        // 三层版本 + 三层源全选齐才亮。
        if (_allReady)
          Text(
            l10n.setupSourceTotalBytes(((_totalBytes + 1048575) ~/ 1048576)),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}


/// 一层 = 版本下拉 + 该层专属源 chips（每 chip 显示按层探测的延迟/可用性）。
/// 标题恒显；版本未选/未到位时版本位占「…」，源区不渲染。
class _LayerCard extends StatelessWidget {
  const _LayerCard({
    super.key,
    required this.label,
    required this.variants,
    required this.selectedKey,
    required this.onVariant,
    required this.sources,
    required this.selectedSourceId,
    required this.onSource,
    required this.probes,
    required this.layer,
  });
  final String label;
  final List<LayerVariant> variants;
  final String selectedKey;
  final ValueChanged<String> onVariant;
  final List<RuntimeSourceInfo> sources;
  final String? selectedSourceId;
  final ValueChanged<String> onSource;
  final Map<String, _ProbeState> probes;
  final String layer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsSection(
      margin: EdgeInsets.zero,
      children: [
        _VariantRow(
          label: label,
          variants: variants,
          selectedKey: selectedKey,
          onChanged: onVariant,
        ),
        if (sources.isNotEmpty)
          // 源列表网格：一行两个、等宽卡片、中间留 8dp 空隙（替代原 Wrap
          // 流式布局——自适应宽导致右缘参差、窄 chip 挤成一团）。
          // 注意不能用 LayoutBuilder 量宽：OnboardingScaffold 的滚动区外层
          // 是 IntrinsicHeight，LayoutBuilder 不支持 intrinsic 高度测量
          // （release 静默返回 0），源列表高度会被算漏 → 页面溢出且无法
          // 滚动（v3r29 实锤）。Row 分对 + 两个 Expanded 同样等宽，且
          // intrinsic 友好；奇数个时末位补空 SizedBox 保持左右等宽。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < sources.length; i += 2)
                  Padding(
                    padding: EdgeInsets.only(bottom: i + 2 < sources.length ? 8 : 0),
                    child: Row(children: [
                      Expanded(
                        child: _SourceChip(
                          source: sources[i],
                          layer: layer,
                          probe: probes['$layer:${sources[i].id}'] ?? const _ProbeState(),
                          selected: selectedSourceId == sources[i].id,
                          onTap: () => onSource(sources[i].id),
                          theme: theme,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        // 奇数收尾：占位保持行内两列等宽。
                        child: i + 1 < sources.length
                            ? _SourceChip(
                                source: sources[i + 1],
                                layer: layer,
                                probe: probes['$layer:${sources[i + 1].id}'] ?? const _ProbeState(),
                                selected: selectedSourceId == sources[i + 1].id,
                                onTap: () => onSource(sources[i + 1].id),
                                theme: theme,
                              )
                            : const SizedBox(),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.source,
    required this.layer,
    required this.probe,
    required this.selected,
    required this.onTap,
    required this.theme,
  });
  final RuntimeSourceInfo source;
  final String layer;
  final _ProbeState probe;
  final bool selected;
  final VoidCallback onTap;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    Widget? tail;
    if (probe.pending) {
      tail = const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5));
    } else if (probe.ok) {
      tail = Text('${probe.latencyMs}ms',
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary));
    } else {
      tail = Icon(AppIcons.close, size: 12, color: theme.colorScheme.error);
    }
    return InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : theme.dividerColor,
            width: selected ? 1.6 : 1,
          ),
          color: selected ? theme.colorScheme.primary.withValues(alpha: 0.08) : null,
        ),
        child: Row(children: [
          // 网格等宽卡片：源名超长截断省略，与尾缀（ms/红叉/转圈）之间
          // 弹性留白，短名不拉伸文字。
          Expanded(
            child: Text(
              source.name,
              style: theme.textTheme.labelMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          tail,
        ]),
      ),
    );
  }
}

class _VariantRow extends StatelessWidget {
  const _VariantRow({required this.label, required this.variants, required this.selectedKey, required this.onChanged});
  final String label;
  final List<LayerVariant> variants;
  final String selectedKey;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    LayerVariant? selected;
    for (final v in variants) {
      if (v.key == selectedKey) selected = v;
    }
    return ListTile(
      dense: true,
      title: Text(label),
      // 版本未到位（index 拉取中/失败）：占「…」，标题照常显示。
      trailing: variants.isEmpty
          ? Text('…', style: Theme.of(context).textTheme.bodyMedium)
          : PopupMenuButton<String>(
              initialValue: selected?.key,
              onSelected: onChanged,
              itemBuilder: (context) => [
                for (final v in variants)
                  PopupMenuItem(
                    value: v.key,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(v.key),
                    ]),
                  ),
              ],
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                // 未选版本占「…」：下拉常可点，纯自选不预填。
                Text(selected?.key ?? '…'),
                const SizedBox(width: 4),
                const Icon(AppIcons.expand, size: 18),
              ]),
            ),
    );
  }
}
