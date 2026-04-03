import 'dart:io';

import 'package:agentos_kernel/src/kernel/agent/model.dart';
import 'package:agentos_kernel/src/kernel/supervision/model_profiler.dart';
import 'package:test/test.dart';

void main() {
  test('persists model profiles across reopen', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'model-profiler-test-',
    );
    final dbPath = '${tempDir.path}/model_profiles.sqlite';
    addTearDown(() async {
      await tempDir.delete(recursive: true);
    });

    final profiler = await ModelProfiler.open(path: dbPath);
    profiler.record(
      LlmCallMetrics(
        meta: LlmRequestMeta(
          id: 'req-1',
          purpose: 'memory_summary',
          priority: 0,
          weight: 1,
          modelKey: 'model-1',
        ),
        startedAt: DateTime(2026, 4, 3, 10, 0, 0),
        doneAt: DateTime(2026, 4, 3, 10, 0, 1),
        success: true,
        totalTokens: 1200,
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    final reopened = await ModelProfiler.open(path: dbPath);
    final profile = reopened.getProfile('model-1');

    expect(profile, isNotNull);
    expect(profile!.totalCalls, 1);
    expect(profile.successCount, 1);
    expect(profile.maxSuccessTokens, 1200);
    expect(profile.purposeTotalCalls('memory_summary'), 1);
  });
}
