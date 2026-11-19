// v3r18 真机排查：footer 双按钮（重新探测/开始下载）在真机不渲染。
// 用 pumpGate 金测骨架 + 假桥，真实走到 选源页，看按钮在不在树、在不在屏内。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';

import 'parallel_setup_support.dart';

class _FakeBridge extends RuntimeBridge {
  @override
  Future<List<RuntimeChannelInfo>> channels() async => const [
        RuntimeChannelInfo(id: 'layers-3', name: 'Layers', isDefault: true),
      ];

  @override
  Future<List<RuntimeSourceInfo>> channelSources() async => const [
        RuntimeSourceInfo(id: 'ghfast', name: 'ghfast.top', prefix: ''),
      ];

  @override
  Future<Map<String, List<RuntimeSourceInfo>>> layerSources() async => const {
        'base': [RuntimeSourceInfo(id: 'ghfast', name: 'ghfast.top', prefix: '')],
        'node': [RuntimeSourceInfo(id: 'ghfast', name: 'ghfast.top', prefix: '')],
        'engine': [RuntimeSourceInfo(id: 'ghfast', name: 'ghfast.top', prefix: '')],
      };

  @override
  Future<String> layerChannelIndex(String channelId, String sourceId) async => '''
    {"layers": {
      "base": {"debian-12": {"asset": "b.tar.gz", "bytes": 123}},
      "node": {"24.9.0": {"asset": "n.tar.gz", "bytes": 456}},
      "engine": {"0.2.2-rc.3": {"asset": "e.tar.gz", "bytes": 789}}
    }}''';

  @override
  Future<Map<Object?, Object?>> probeLayerSource(
          String channelId, String layer, String sourceId, {String? nodeVersion}) async =>
      {'ok': true, 'latencyMs': 100};
}

void main() {
  testWidgets('选源页 footer 双按钮渲染且在屏内', (tester) async {
    await pumpGate(tester, overrides: [
      runtimeBridgeProvider.overrideWithValue(_FakeBridge()),
    ]);
    expect(find.text('DSH 在哪里运行？'), findsOneWidget);
    await chooseThisPhone(tester);
    await frames(tester, 10);

    // build 标记（确认跑的是新代码路径）
    expect(find.text('build v3r25'), findsOneWidget);

    final reprobe = find.text('重新探测');
    final start = find.text('开始下载');
    debugPrint('reprobe hits: ${reprobe.evaluate().length}, start hits: ${start.evaluate().length}');
    expect(reprobe, findsOneWidget);
    expect(start, findsOneWidget);

    // 屏内可见性（不被布局到屏幕外）
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    for (final f in [reprobe, start]) {
      final ro = tester.firstRenderObject<RenderBox>(f);
      final top = ro.localToGlobal(Offset.zero).dy;
      debugPrint('button top=$top screenH=${screen.height}');
      expect(top < screen.height, isTrue, reason: '按钮 top 超出屏幕');
    }
  });
}
