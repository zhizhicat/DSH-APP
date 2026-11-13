import 'dart:async';
import 'dart:convert';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/settings_state.dart';
import '../state/read_list_epoch.dart';
import 'runtime_bridge.dart';

final runtimeBridgeProvider = Provider<RuntimeBridge>((ref) => RuntimeBridge());

/// [RuntimeBridge.batteryExempt]; invalidate to read it again.
final batteryExemptProvider = FutureProvider<bool?>((ref) => ref.watch(runtimeBridgeProvider).batteryExempt());

/// A one-off message from the runtime (e.g. "已用安全模式启动"); [seq] tells repeats apart.
class RuntimeNotice {
  const RuntimeNotice(this.seq, this.text);
  final int seq;
  final String text;
}

/// What the UI needs to know about the local runtime.
class LocalRuntimeState {
  const LocalRuntimeState({
    this.status = const RuntimeStatus.unknown(),
    this.progress,
    this.loaded = false,
    this.notice,
  });

  final RuntimeStatus status;
  final RuntimeProgressEvent? progress;

  /// False until the first status arrives from the native side.
  final bool loaded;

  /// The latest notice; shown once by `SafeModeNoticeListener`.
  final RuntimeNotice? notice;

  LocalRuntimeState copyWith({
    RuntimeStatus? status,
    RuntimeProgressEvent? progress,
    bool clearProgress = false,
    bool? loaded,
    RuntimeNotice? notice,
  }) => LocalRuntimeState(
    status: status ?? this.status,
    progress: clearProgress ? null : (progress ?? this.progress),
    loaded: loaded ?? this.loaded,
    notice: notice ?? this.notice,
  );
}

class LocalRuntimeController extends Notifier<LocalRuntimeState> {
  StreamSubscription<RuntimeEvent>? _sub;
  var _statusRevision = 0;

  RuntimeBridge get _bridge => ref.read(runtimeBridgeProvider);

  @override
  LocalRuntimeState build() {
    // Keep collecting before the log screen opens, without watching its updates.
    ref.read(localRuntimeLogsProvider);
    _sub = _bridge.events.listen(_onEvent, onError: (_) {});
    ref.onDispose(() => _sub?.cancel());
    unawaited(_refresh());
    return const LocalRuntimeState();
  }

  Future<void> _refresh() async {
    final r = ref;
    // A later query or status event retires this in-flight snapshot.
    final revision = ++_statusRevision;
    try {
      final status = await _bridge.status();
      if (!r.mounted || revision != _statusRevision) return;
      state = state.copyWith(status: status, loaded: true, clearProgress: status.phase != RuntimePhase.installing);
    } catch (_) {
      if (r.mounted && revision == _statusRevision) state = state.copyWith(loaded: true);
    }
  }

  void _onEvent(RuntimeEvent event) {
    switch (event) {
      case RuntimeStatusEvent(:final status):
        _statusRevision++;
        state = state.copyWith(status: status, loaded: true, clearProgress: status.phase != RuntimePhase.installing);
      case RuntimeProgressEvent():
        state = state.copyWith(progress: event);
      case RuntimeLogsEvent():
        break;
      case RuntimeNoticeEvent(:final text):
        state = state.copyWith(notice: RuntimeNotice((state.notice?.seq ?? 0) + 1, text));
    }
  }

  Future<void> install() {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    return _bridge.install();
  }

  /// Installs without what a reset kept but could not put back.
  Future<void> installDroppingKept() {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    return _bridge.install(dropKept: true);
  }

  /// Download channels for noruntime builds.
  Future<List<RuntimeChannelInfo>> channels() => _bridge.channels();

  // ---- Variant channels (schema 3) ----

  Future<List<RuntimeSourceInfo>> channelSources() => _bridge.channelSources();

  Future<Map<Object?, Object?>> probeSource(String channelId, String sourceId) =>
      _bridge.probeChannelSource(channelId, sourceId);

  /// Fetches and parses the layers index for [channelId] through [sourceId].
  Future<LayersIndex?> layersIndex(String channelId, String sourceId) async {
    try {
      final raw = await _bridge.layerChannelIndex(channelId, sourceId);
      return LayersIndex.parse(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> installLayerChannel({
    required String channelId,
    required String sourceId,
    required LayersChoice choice,
  }) {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    return _bridge.installLayerChannel(
      channelId: channelId,
      sourceId: sourceId,
      base: choice.base,
      node: choice.node,
      engine: choice.engine,
    );
  }

  /// Remembers the person's last mirror + layer selection for next installs.
  static Future<void> saveVariantPrefs({
    required String sourceId,
    required LayersChoice choice,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('runtime.variant.sourceId', sourceId);
    await prefs.setString('runtime.variant.base', choice.base);
    await prefs.setString('runtime.variant.node', choice.node);
    await prefs.setString('runtime.variant.engine', choice.engine);
  }

  static Future<({String sourceId, LayersChoice? choice})> loadVariantPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final sourceId = prefs.getString('runtime.variant.sourceId') ?? '';
    final base = prefs.getString('runtime.variant.base');
    final node = prefs.getString('runtime.variant.node');
    final engine = prefs.getString('runtime.variant.engine');
    if (base == null || node == null || engine == null) return (sourceId: sourceId, choice: null);
    return (sourceId: sourceId, choice: LayersChoice(base: base, node: node, engine: engine));
  }

  /// noruntime first install: download the channel, then unpack.
  Future<void> installChannel(RuntimeChannelInfo channel) {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    return _bridge.installChannel(channel.id);
  }

  /// The API key is not passed here: it is written to DSH's own credential store
  /// after connecting (see connection_state.dart), so it can change without a restart.
  /// Keeps the current mode: in safe mode this starts safe mode again.
  Future<void> start() {
    final settings = ref.read(settingsProvider);
    return _bridge.start(phoneStorage: settings.phoneStorage, visualReplies: settings.visualReplies);
  }

  /// Starts in [mode]; [EngineMode.normal] from safe mode begins the two-minute trial.
  Future<void> startIn(EngineMode mode) {
    final settings = ref.read(settingsProvider);
    return _bridge.start(phoneStorage: settings.phoneStorage, visualReplies: settings.visualReplies, mode: mode);
  }

  Future<void> stop() => _bridge.stop();

  Future<void> reset() => resetKeeping(const ResetKeep());

  /// Resets the runtime; [keep] comes back with the next install.
  Future<void> resetKeeping(ResetKeep keep) async {
    final r = ref;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await _bridge.reset(keep: keep);
    if (r.mounted) await _refresh();
  }
}

final localRuntimeProvider = NotifierProvider<LocalRuntimeController, LocalRuntimeState>(LocalRuntimeController.new);

/// The last 1000 engine log lines. The native snapshot and the live batches share
/// one sequence, so batches that arrive while the snapshot is read are neither lost
/// nor shown twice.
class LocalRuntimeLogsController extends Notifier<List<String>> {
  static const _maxLogs = 1000;

  @override
  List<String> build() {
    final r = ref;
    final bridge = r.read(runtimeBridgeProvider);
    final lines = ListQueue<String>();
    final pending = ListQueue<RuntimeLogEntry>();
    var loading = true;
    var throughSeq = 0;

    bool append(Iterable<RuntimeLogEntry> entries) {
      var changed = false;
      for (final entry in entries) {
        if (entry.seq <= throughSeq) continue;
        lines.addLast(entry.line);
        if (lines.length > _maxLogs) lines.removeFirst();
        throughSeq = entry.seq;
        changed = true;
      }
      return changed;
    }

    final sub = bridge.events.listen((event) {
      if (event is! RuntimeLogsEvent) return;
      if (loading) {
        pending.addAll(event.entries);
        while (pending.length > _maxLogs) {
          pending.removeFirst();
        }
      } else if (append(event.entries)) {
        state = List.unmodifiable(lines);
      }
    }, onError: (_) {});
    r.onDispose(sub.cancel);

    Future<void> bootstrap() async {
      try {
        final snapshot = await bridge.logSnapshot();
        if (!r.mounted) return;
        append(snapshot.entries);
        throughSeq = snapshot.throughSeq;
      } catch (_) {
        // Live batches still give a useful tail.
        if (!r.mounted) return;
      }
      append(pending);
      pending.clear();
      loading = false;
      state = List.unmodifiable(lines);
    }

    unawaited(bootstrap());
    return const [];
  }
}

final localRuntimeLogsProvider = NotifierProvider<LocalRuntimeLogsController, List<String>>(
  LocalRuntimeLogsController.new,
);


/// Parsed layers-index.json (schema 3): layer packages the person can mix.
class LayersIndex {
  const LayersIndex({required this.base, required this.node, required this.engine});
  final List<LayerVariant> base;
  final List<LayerVariant> node;
  final List<LayerVariant> engine;

  static LayersIndex? parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      List<LayerVariant> read(String kind) {
        final map = decoded['layers']?[kind];
        if (map is! Map<String, dynamic>) return const [];
        return [
          for (final e in map.entries)
            LayerVariant(
              key: e.key,
              asset: (e.value as Map<String, dynamic>)['asset'] as String? ?? '',
              bytes: ((e.value as Map<String, dynamic>)['bytes'] as num?)?.toInt() ?? 0,
            ),
        ]..sort((a, b) => b.key.compareTo(a.key));
      }
      final index = LayersIndex(base: read('base'), node: read('node'), engine: read('engine'));
      if (index.base.isEmpty || index.node.isEmpty || index.engine.isEmpty) return null;
      return index;
    } catch (_) {
      return null;
    }
  }
}

class LayerVariant {
  const LayerVariant({required this.key, required this.asset, required this.bytes});
  final String key;
  final String asset;
  final int bytes;
}

class LayersChoice {
  const LayersChoice({required this.base, required this.node, required this.engine});
  final String base;
  final String node;
  final String engine;
}
