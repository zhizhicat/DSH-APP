import 'dart:async';

import 'package:dsh_app/tavern/deferred_tavern.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_test/flutter_test.dart';

class _Run implements TavernAuthoringRun {
  _Run(this.runId);

  @override
  final String runId;
  var cancelled = false;

  @override
  Stream<TavernAuthoringRunEvent> get events => const Stream.empty();

  @override
  Future<TavernAuthoringRunSnapshot> get result => Completer<TavernAuthoringRunSnapshot>().future;

  @override
  Future<void> cancel() async => cancelled = true;
}

/// A trial the engine started: what it shows so far, and whether it was stopped.
class _Simulation implements TavernAuthoringSimulationTask {
  var cancelled = false;

  @override
  String get requestId => 't1';

  @override
  TavernAuthoringSimulationResult get view => const TavernAuthoringSimulationResult(
    requestId: 't1',
    captureId: 'engine-capture',
    draftId: 'd1',
    draftRevision: 1,
    changeIds: [],
    status: TavernAuthoringSimulationStatus.running,
    origin: {},
    turns: [],
    requests: [],
    usage: {},
    cleanup: {},
    issues: [],
  );

  @override
  Future<TavernAuthoringSimulationResult> get result => Completer<TavernAuthoringSimulationResult>().future;

  @override
  Future<void> cancel() async => cancelled = true;
}

class _Authoring extends PreviewTavern {
  _Authoring() : super(tick: Duration.zero);

  TavernAuthoringSimulationRequest? tried;

  @override
  TavernAuthoringSimulationTask simulateAuthoringDraft(TavernAuthoringSimulationRequest request) {
    tried = request;
    return _Simulation();
  }

  _Run? started;

  @override
  TavernAuthoringRun startAuthoringRun(
    TavernAuthoringRunRequest request, {
    TavernAuthoringPromptHost? promptHost,
    TavernAuthoringPreviewHost? renderHost,
  }) => started = _Run(request.runId);
}

void main() {
  test('an authoring run asked for before it opens has its id at once and starts once it opens', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    final run = deferred.startAuthoringRun(
      const TavernAuthoringRunRequest(runId: 'r1', draftId: 'd1', draftRevision: 1, instruction: '写一张卡'),
    );
    expect(run.runId, 'r1');

    final engine = _Authoring();
    opening.complete(engine);
    await run.cancel();
    expect(engine.started?.runId, 'r1');
    expect(engine.started!.cancelled, isTrue);
  });

  test('a trial asked for before it opens shows nothing run yet, then the engine\'s own', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    final trial = deferred.simulateAuthoringDraft(
      TavernAuthoringSimulationRequest(
        requestId: 't1',
        draftId: 'd1',
        draftRevision: 1,
        changeIds: const [],
        context: const TavernAuthoringSampleContext(characterResourceId: 'character:lin'),
        userInputs: const ['你好'],
        at: DateTime.utc(2026, 11, 14),
        seed: 1,
      ),
    );
    expect(trial.requestId, 't1');
    expect(trial.view.status, TavernAuthoringSimulationStatus.running);
    expect(trial.view.turns, isEmpty);

    final engine = _Authoring();
    opening.complete(engine);
    await trial.cancel();
    expect(engine.tried!.userInputs, ['你好']);
    expect(trial.view.captureId, 'engine-capture');
  });

  test('calls and streams wait for the tavern to open; configure reaches it then', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future)
      ..configure(TavernModelConfig(apiKey: () async => 'k', thinking: true));

    final characters = deferred.watchCharacters().first;
    final chat = deferred.createChat('sample-innkeeper');
    deferred.stop('nothing yet'); // no turn can run before it opens

    final preview = PreviewTavern(tick: const Duration(milliseconds: 1));
    opening.complete(preview);

    expect((await characters).map((c) => c.name), containsAll(['林晚', '星图']));
    final events = await deferred.send(await chat, '你好').toList();
    // The thinking set before it opened applies: the reply thinks first.
    expect(events.whereType<TavernReasoningDelta>(), isNotEmpty);
    expect(events.last, isA<TavernTurnDone>());
  });

  test('the libraries and the display pass reach the engine once it opens (T20, T21)', () async {
    final preview = PreviewTavern(tick: Duration.zero);
    final chat = await preview.createChat('sample-innkeeper');
    final deferred = DeferredTavern(Future.value(preview));

    expect(await deferred.listPresets(), isEmpty);
    expect(await deferred.watchPresets().first, isEmpty);
    expect((await deferred.presetSelection(chatId: chat)).source, PresetSelectionSource.stDefault);
    expect(await deferred.listRegexScripts(), isEmpty);
    expect(await deferred.listLorebooks(), isEmpty);
    expect((await deferred.displayText(chat, text: '*她笑了*')).text, '*她笑了*');
    // Presets and lorebooks go through to the preview's own.
    final imported = await deferred.importPreset('{"temperature": 1}', fileName: 'a.json');
    expect((await deferred.listPresets()).single.id, imported.preset.id);
    final book = await deferred.importLorebook('{"entries": {"0": {"content": "x"}}}', fileName: 'w.json');
    expect((await deferred.listLorebooks()).single.id, book.book.id);
  });
}
