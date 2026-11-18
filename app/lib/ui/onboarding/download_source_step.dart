// Variant channels (schema 3), before 选择外观 on a noruntime first run:
// pick a download mirror (probed live), then base / node / engine versions
// from the layers index. 开始下载 hands over to the usual unpack flow.

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
  /// v1.5 三层分源探测结果：'layer:sourceId' -> state。
  final Map<String, _ProbeState> _layerProbes = {};
  String? _layerChannelId;
  String? _sourceId;
  String? _nodeSourceId;
  String? _engineSourceId;
  LayersIndex? _index;
  LayersChoice? _choice;
  bool _indexLoading = false;
  String? _indexError;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<String?> _layerChannel() async {
    if (_layerChannelId != null) return _layerChannelId;
    final channels = await ref.read(localRuntimeProvider.notifier).channels();
    for (final c in channels) {
      if (c.id.contains('layers')) {
        _layerChannelId = c.id;
        break;
      }
    }
    return _layerChannelId;
  }

  Future<void> _init() async {
    final controller = ref.read(localRuntimeProvider.notifier);
    final sources = await controller.channelSources();
    Map<String, List<RuntimeSourceInfo>> layerSources = const {};
    try {
      layerSources = await controller.layerSources();
    } catch (_) {/* 三层源池是 v1.5 新桥：旧原生回退到单源池 */}
    final channelId = await _layerChannel();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _layerSources = layerSources;
    });
    final saved = await LocalRuntimeController.loadVariantPrefs();
    final sourceId = _sources.any((s) => s.id == saved.sourceId)
        ? saved.sourceId
        : (_sources.isEmpty ? null : _sources.first.id);
    _nodeSourceId = _validLayerSource('node', saved.nodeSourceId) ??
        _validLayerSource('node', sourceId);
    _engineSourceId = _validLayerSource('engine', saved.engineSourceId) ??
        _validLayerSource('engine', sourceId);
    if (sourceId != null && channelId != null) {
      unawaited(_selectSource(sourceId, saved.choice));
    }

    // 三层分源探测（gh 镜像三层可各选不同）。
    for (final layer in const ['base', 'node', 'engine']) {
      for (final src in _layerSources[layer] ?? const <RuntimeSourceInfo>[]) {
        unawaited(_probeLayer(layer, src.id, nodeVersion: saved.choice?.node));
      }
    }
  }

  bool _reprobing = false;

  /// 重新探测三层全部源(保留选择,清空旧结果让 chips 重新显示探测中)。
  Future<void> _reprobeAll() async {
    if (_reprobing) return;
    setState(() {
      _reprobing = true;
      _layerProbes.clear();
    });
    final nodeVersion = _choice?.node;
    final layers = const ['base', 'node', 'engine'];
    final futures = <Future<void>>[];
    for (final layer in layers) {
      for (final src in _layerSources[layer] ?? const <RuntimeSourceInfo>[]) {
        futures.add(_probeLayer(layer, src.id, nodeVersion: nodeVersion));
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


  /// 选源入口：失败时按剩余源自动故障转移（探测延迟低者优先，最多轮完）。
  Future<void> _selectSource(String sourceId, LayersChoice? preferred) async {
    final tried = <String>{sourceId};
    var current = sourceId;
    while (true) {
      final failed = await _fetchIndexOnce(current, preferred);
      if (!failed) return;
      final next = _nextSourceAfter(current, tried);
      if (next == null || !mounted) return;
      tried.add(next);
      current = next;
      if (mounted) setState(() => _sourceId = next);
    }
  }

  String? _nextSourceAfter(String id, Set<String> tried) {
    final pool = _layerSources['base'] ?? _sources;
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

  /// 拉一次 index；返回 true=失败（可故障转移）。
  Future<bool> _fetchIndexOnce(String sourceId, LayersChoice? preferred) async {
    setState(() {
      _sourceId = sourceId;
      _index = null;
      _indexError = null;
      _indexLoading = true;
    });
    final channelId = await _layerChannel();
    if (channelId == null) {
      if (mounted) setState(() { _indexLoading = false; _indexError = context.l10n.setupSourceIndexFailed; });
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
        _choice = null;
      } else {
        _indexError = null;
        _choice = _validChoice(preferred, index) ?? LayersChoice.defaultFor(index);
      }
    });
    return index == null;
  }

  /// Applies a layer pick and remembers it right away, so leaving mid-download
  /// still resumes into the same selection (the download itself caches too).
  void _pick(LayersChoice choice) {
    setState(() => _choice = choice);
    final sourceId = _sourceId;
    if (sourceId != null) {
      unawaited(LocalRuntimeController.saveVariantPrefs(
        sourceId: sourceId,
        choice: choice,
        nodeSourceId: _nodeSourceId,
        engineSourceId: _engineSourceId,
      ));
    }
  }

  void _pickLayerSource(String layer, String id) {
    setState(() {
      switch (layer) {
        case 'node':
          _nodeSourceId = id;
        case 'engine':
          _engineSourceId = id;
      }
    });
    final sourceId = _sourceId;
    final choice = _choice;
    if (sourceId != null && choice != null) {
      unawaited(LocalRuntimeController.saveVariantPrefs(
        sourceId: sourceId,
        choice: choice,
        nodeSourceId: _nodeSourceId,
        engineSourceId: _engineSourceId,
      ));
    }
  }

  /// Engine pick with a pure-build heads-up: -pure layers are unpatched
  /// upstream builds (no Android fixes / phone channel / security patches).
  void _pickEngine(String key) {
    final previous = _choice;
    _pick(LayersChoice(base: _choice!.base, node: _choice!.node, engine: key));
    if (!key.endsWith('-pure')) return;
    final l10n = context.l10n;
    unawaited(showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.setupPureTitle),
        content: Text(l10n.setupPureBody),
        actions: [
          TextButton(
            // Back to the adapted build: restores the previous engine pick.
            onPressed: () {
              Navigator.of(dialogContext).pop();
              if (previous != null && previous.engine != key) _pick(previous);
            },
            child: Text(l10n.setupPureCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.setupPureConfirm),
          ),
        ],
      ),
    ));
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return OnboardingScaffold(
      footer: Row(
        children: [
          OutlinedButton(
            onPressed: _reprobing ? null : _reprobeAll,
            // 64 = 按钮类默认最小宽。不能用 Size.fromHeight(52)：
            // fromHeight 的宽是 infinity，在 Row（不约束宽）里就是
            // infinite width 布局错误，release 下断言剥掉后整个按钮静默消失。
            style: OutlinedButton.styleFrom(minimumSize: const Size(64, 52)),
            child: _reprobing
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.setupSourceReprobe),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: _sourceId == null || _choice == null
                  ? null
                  : () async {
                      await LocalRuntimeController.saveVariantPrefs(
                        sourceId: _sourceId!,
                        choice: _choice!,
                        nodeSourceId: _nodeSourceId,
                        engineSourceId: _engineSourceId,
                      );
                      widget.onDone(_sourceId!, _choice!);
                    },
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
          'build v3r18',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        // 索引未到位也先亮三卡：源 chips 可选可换源重试，版本行显示占位。
        if (_indexLoading || _indexError != null || _index == null) ...[
          if (_indexError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_indexError!, style: Theme.of(context).textTheme.bodySmall),
            ),
          _LayerCard(
            key: const ValueKey('setup-layer-base-skeleton'),
            label: l10n.setupSourceRootfs,
            variants: const [],
            selectedKey: '',
            onVariant: (_) {},
            sources: _layerSources['base'] ?? _sources,
            selectedSourceId: _sourceId,
            onSource: (id) => unawaited(_selectSource(id, _choice)),
            probes: _layerProbes,
            layer: 'base',
            loading: _indexError != null ? l10n.setupSourceIndexFailed : '…',
          ),
          const SizedBox(height: 12),
          _LayerCard(
            key: const ValueKey('setup-layer-node-skeleton'),
            label: l10n.setupSourceNode,
            variants: const [],
            selectedKey: '',
            onVariant: (_) {},
            sources: _layerSources['node'] ?? const [],
            selectedSourceId: _nodeSourceId ?? _sourceId,
            onSource: (id) => _pickLayerSource('node', id),
            probes: _layerProbes,
            layer: 'node',
            loading: '…',
          ),
          const SizedBox(height: 12),
          _LayerCard(
            key: const ValueKey('setup-layer-engine-skeleton'),
            label: l10n.setupSourceDsh,
            variants: const [],
            selectedKey: '',
            onVariant: (_) {},
            sources: _layerSources['engine'] ?? const [],
            selectedSourceId: _engineSourceId ?? _sourceId,
            onSource: (id) => _pickLayerSource('engine', id),
            probes: _layerProbes,
            layer: 'engine',
            loading: '…',
          ),
          const SizedBox(height: 12),
        ]
        else if (_index != null && _choice != null) ...[
          // v1.5 三层卡片：每层 = 版本下拉 + 该层专属源 chips（各配各的镜像）。
          _LayerCard(
            key: const ValueKey('setup-layer-base'),
            label: l10n.setupSourceRootfs,
            variants: _index!.base,
            selectedKey: _choice!.base,
            onVariant: (k) => _pick(LayersChoice(base: k, node: _choice!.node, engine: _choice!.engine)),
            sources: _layerSources['base'] ?? const [],
            selectedSourceId: _sourceId,
            onSource: (id) => unawaited(_selectSource(id, _choice)),
            probes: _layerProbes,
            layer: 'base',
          ),
          const SizedBox(height: 12),
          _LayerCard(
            key: const ValueKey('setup-layer-node'),
            label: l10n.setupSourceNode,
            variants: _index!.node,
            selectedKey: _choice!.node,
            onVariant: (k) => _pick(LayersChoice(base: _choice!.base, node: k, engine: _choice!.engine)),
            sources: _layerSources['node'] ?? const [],
            selectedSourceId: _nodeSourceId ?? _sourceId,
            onSource: (id) => _pickLayerSource('node', id),
            probes: _layerProbes,
            layer: 'node',
          ),
          const SizedBox(height: 12),
          _LayerCard(
            key: const ValueKey('setup-layer-engine'),
            label: l10n.setupSourceDsh,
            variants: _index!.engine,
            selectedKey: _choice!.engine,
            onVariant: (k) => _pickEngine(k),
            sources: _layerSources['engine'] ?? const [],
            selectedSourceId: _engineSourceId ?? _sourceId,
            onSource: (id) => _pickLayerSource('engine', id),
            probes: _layerProbes,
            layer: 'engine',
          ),
          const SizedBox(height: 12),
          Text(
            l10n.setupSourceTotalBytes(((_totalBytes + 1048575) ~/ 1048576)),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}


/// 一层 = 版本下拉 + 该层专属源 chips（每 chip 显示按层探测的延迟/可用性）。
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
    this.loading = '',
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
  final String loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsSection(
      margin: EdgeInsets.zero,
      children: [
        variants.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(loading, style: theme.textTheme.bodySmall),
              )
            : _VariantRow(
                label: label,
                variants: variants,
                selectedKey: selectedKey,
                onChanged: onVariant,
              ),
        if (sources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final src in sources)
                  _SourceChip(
                    source: src,
                    layer: layer,
                    probe: probes['$layer:${src.id}'] ?? const _ProbeState(),
                    selected: selectedSourceId == src.id,
                    onTap: () => onSource(src.id),
                    theme: theme,
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
          color: selected ? theme.colorScheme.primary.withOpacity(0.08) : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(source.name, style: theme.textTheme.labelMedium),
          const SizedBox(width: 6),
          tail!,
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
    final selected = variants.firstWhere((v) => v.key == selectedKey, orElse: () => variants.first);
    final l10n = context.l10n;
    // -pure engine keys: strip the suffix for display and badge the row.
    String shown(String key) => key.endsWith('-pure') ? key.substring(0, key.length - 5) : key;
    Widget? badge(String key) => key.endsWith('-pure')
        ? Text(l10n.setupSourcePureBadge,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.tertiary))
        : null;
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: variants.length > 1 ? null : Text(shown(selected.key), style: Theme.of(context).textTheme.bodySmall),
      trailing: variants.length > 1
          ? PopupMenuButton<String>(
              initialValue: selectedKey,
              onSelected: onChanged,
              itemBuilder: (context) => [
                for (final v in variants)
                  PopupMenuItem(
                    value: v.key,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(shown(v.key)),
                      if (badge(v.key) != null) ...[
                        const SizedBox(width: 8),
                        badge(v.key)!,
                      ],
                    ]),
                  ),
              ],
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(shown(selected.key)),
                if (badge(selectedKey) != null) ...[
                  const SizedBox(width: 6),
                  badge(selectedKey)!,
                ],
                const SizedBox(width: 4),
                const Icon(AppIcons.expand, size: 18),
              ]),
            )
          : null,
    );
  }
}
