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
  const DownloadSourceStepPage({super.key, required this.onDone});

  /// Called with the chosen source id + layers choice when 开始下载 is tapped.
  final void Function(String sourceId, LayersChoice choice) onDone;

  @override
  ConsumerState<DownloadSourceStepPage> createState() => _DownloadSourceStepPageState();
}

class _DownloadSourceStepPageState extends ConsumerState<DownloadSourceStepPage> {
  List<RuntimeSourceInfo> _sources = const [];
  final Map<String, _ProbeState> _probes = {};
  String? _layerChannelId;
  String? _sourceId;
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
    final channelId = await _layerChannel();
    if (!mounted) return;
    setState(() => _sources = sources);
    final saved = await LocalRuntimeController.loadVariantPrefs();
    final sourceId = _sources.any((s) => s.id == saved.sourceId)
        ? saved.sourceId
        : (_sources.isEmpty ? null : _sources.first.id);
    if (sourceId != null && channelId != null) {
      unawaited(_selectSource(sourceId, saved.choice));
    }
    for (final s in sources) {
      unawaited(_probe(s));
    }
  }

  Future<void> _probe(RuntimeSourceInfo source) async {
    final channelId = await _layerChannel();
    if (channelId == null || !mounted) return;
    final result = await ref.read(localRuntimeProvider.notifier).probeSource(channelId, source.id);
    if (!mounted) return;
    setState(() {
      _probes[source.id] = (_probes[source.id] ?? const _ProbeState())
          .withResult(ok: result['ok'] == true, latencyMs: (result['latencyMs'] as num?)?.toInt() ?? -1);
    });
  }

  Future<void> _selectSource(String sourceId, LayersChoice? preferred) async {
    setState(() {
      _sourceId = sourceId;
      _index = null;
      _indexError = null;
      _indexLoading = true;
    });
    final channelId = await _layerChannel();
    if (channelId == null) {
      if (mounted) setState(() { _indexLoading = false; _indexError = context.l10n.setupSourceIndexFailed; });
      return;
    }
    final index = await ref.read(localRuntimeProvider.notifier).layersIndex(channelId, sourceId);
    if (!mounted) return;
    setState(() {
      _indexLoading = false;
      _index = index;
      if (index == null) {
        _indexError = context.l10n.setupSourceIndexFailed;
        _choice = null;
      } else {
        _choice = _validChoice(preferred, index) ??
            LayersChoice(base: index.base.first.key, node: index.node.first.key, engine: index.engine.first.key);
      }
    });
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
      children: [
        const Spacer(),
        OnboardingHeader(
          icon: AppIcons.download,
          title: l10n.setupSourceTitle,
          message: l10n.setupSourceMessage,
        ),
        const SizedBox(height: 28),
        SettingsSection(
          key: const ValueKey('setup-source-card'),
          margin: EdgeInsets.zero,
          children: [
            for (final source in _sources)
              _SourceRow(
                source: source,
                probe: _probes[source.id] ?? const _ProbeState(),
                selectedId: _sourceId,
                onTap: () => unawaited(_selectSource(source.id, _choice)),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (_indexLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (_indexError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(_indexError!, style: Theme.of(context).textTheme.bodySmall),
          )
        else if (_index != null && _choice != null) ...[
          SettingsSection(
            key: const ValueKey('setup-variants-card'),
            margin: EdgeInsets.zero,
            children: [
              _VariantRow(
                label: l10n.setupSourceRootfs,
                variants: _index!.base,
                selectedKey: _choice!.base,
                onChanged: (k) => setState(() => _choice = LayersChoice(base: k, node: _choice!.node, engine: _choice!.engine)),
              ),
              _VariantRow(
                label: l10n.setupSourceNode,
                variants: _index!.node,
                selectedKey: _choice!.node,
                onChanged: (k) => setState(() => _choice = LayersChoice(base: _choice!.base, node: k, engine: _choice!.engine)),
              ),
              _VariantRow(
                label: l10n.setupSourceDsh,
                variants: _index!.engine,
                selectedKey: _choice!.engine,
                onChanged: (k) => setState(() => _choice = LayersChoice(base: _choice!.base, node: _choice!.node, engine: k)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            l10n.setupSourceTotalBytes(((_totalBytes + 1048575) ~/ 1048576)),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _sourceId == null || _choice == null
              ? null
              : () async {
                  await LocalRuntimeController.saveVariantPrefs(sourceId: _sourceId!, choice: _choice!);
                  widget.onDone(_sourceId!, _choice!);
                },
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: Text(l10n.setupSourceStart),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source, required this.probe, required this.selectedId, required this.onTap});
  final RuntimeSourceInfo source;
  final _ProbeState probe;
  final String? selectedId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget? trailing;
    if (probe.pending) {
      trailing = const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (probe.ok) {
      trailing = Text('${probe.latencyMs}ms',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary));
    } else {
      trailing = Icon(AppIcons.close, size: 16, color: theme.colorScheme.error);
    }
    return ListTile(
      dense: true,
      title: Text(source.name),
      trailing: trailing,
      leading: Radio<String>(
        value: source.id,
        groupValue: selectedId,
        onChanged: (_) => onTap(),
      ),
      onTap: onTap,
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
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: variants.length > 1 ? null : Text(selected.key, style: Theme.of(context).textTheme.bodySmall),
      trailing: variants.length > 1
          ? PopupMenuButton<String>(
              initialValue: selectedKey,
              onSelected: onChanged,
              itemBuilder: (context) => [
                for (final v in variants)
                  PopupMenuItem(value: v.key, child: Text(v.key)),
              ],
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(selected.key),
                const SizedBox(width: 4),
                const Icon(Icons.expand_more, size: 18),
              ]),
            )
          : null,
    );
  }
}
