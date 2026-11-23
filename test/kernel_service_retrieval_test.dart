import 'package:agentos_kernel/agentos_kernel.dart';
import 'package:agentos_kernel/src/kernel/kernel.dart';
import 'package:agentos_kernel/src/kernel/memory/drift_memory.dart';
import 'package:agentos_kernel/src/kernel/memory/memory_pipeline.dart';
import 'package:agentos_kernel/src/kernel/opentool/opentool_daemon_registry.dart';
import 'package:agentos_kernel/src/kernel/preference/drift_preference.dart';
import 'package:agentos_kernel/src/kernel/preference/preference_extractor.dart';
import 'package:agentos_kernel/src/kernel/supervision/supervision.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  late DriftMemory memory;
  late DriftPreference preference;
  late KernelService service;

  setUp(() {
    final memoryDb = NativeDatabase.memory();
    final preferenceDb = NativeDatabase.memory();
    addTearDown(memoryDb.close);
    addTearDown(preferenceDb.close);
    memory = DriftMemory(memoryDb);
    preference = DriftPreference(executor: preferenceDb);
    service = KernelService(
      Kernel(
        openToolDaemonRegistry: OpenToolDaemonRegistry(),
        supervision: AdaptiveSupervision(
          ttftThreshold: const Duration(seconds: 5),
          tpsThreshold: 5,
        ),
        memory: memory,
        memoryPipeline: MemoryPipeline(memory: memory),
        preference: preference,
        preferenceExtractor: OfflinePreferenceExtractor(),
      ),
    );
  });

  test(
    'matches whole words and ranks memory by coverage then recency',
    () async {
      final now = DateTime.now();
      const bucket = MemorySummaryBucket.recent;
      await memory.saveMemorySummaries(bucket, [
        _summary(
          'old',
          'Plan the release and review',
          now.subtract(const Duration(hours: 1)),
        ),
        _summary('new', 'Release review notes', now),
        _summary(
          'duplicate',
          'RELEASE REVIEW NOTES',
          now.subtract(const Duration(minutes: 10)),
        ),
        _summary('partial', 'Release checklist', now),
        _summary('nonmatch', 'Pre-releaseboard preview', now),
      ]);

      final results = await service.retrieveRelevantMemorySummaries(
        'RELEASE release, review',
      );
      expect(results.map((item) => item.id), ['new', 'old', 'partial']);

      final limited = await service.retrieveRelevantMemorySummaries(
        'release review',
        candidateLimit: 1,
      );
      expect(limited.single.id, 'new');
    },
  );

  test('uses memory time buckets and fills unused slots', () async {
    final now = DateTime.now();
    const recent = MemorySummaryBucket.recent;
    const archive = MemorySummaryBucket.archive;
    await memory.saveMemorySummaries(recent, [
      for (var i = 1; i <= 4; i++)
        _summary(
          'recent-$i',
          'Release note $i',
          now.subtract(Duration(minutes: i)),
        ),
    ]);
    await memory.saveMemorySummaries(archive, [
      _summary(
        'archived',
        'Release history',
        now.subtract(const Duration(days: 100)),
        bucket: archive,
      ),
    ]);

    final results = await service.retrieveRelevantMemorySummaries('release');
    expect(results.map((item) => item.id), [
      'recent-1',
      'recent-2',
      'recent-3',
      'archived',
      'recent-4',
    ]);
  });

  test(
    'matches Chinese text and scopes preferences before candidate selection',
    () async {
      final now = DateTime.now();
      await memory.saveMemorySummaries(MemorySummaryBucket.recent, [
        _summary('meeting', '团队下周讨论发布计划', now),
        _summary('unrelated', '每周整理会议纪要', now),
      ]);
      await preference.addTexts(
        userId: 'u1',
        texts: const ['发布计划使用表格'],
        updatedAt: now.subtract(const Duration(days: 1)),
      );
      await preference.addTexts(
        userId: 'u1',
        texts: const ['发布计划保持简洁'],
        updatedAt: now,
      );
      await preference.addTexts(
        userId: service.defaultUserId,
        texts: const ['详细说明发布计划'],
        updatedAt: now.add(const Duration(minutes: 1)),
      );

      final context = await service.retrieveRelevantContext(
        '请写发布计划',
        userId: ' u1 ',
        preferenceCandidateLimit: 1,
      );
      expect(context.memorySummaries.single.id, 'meeting');
      expect(context.preferences.single.text, '发布计划保持简洁');

      final singleCharacter = await service.retrieveRelevantMemorySummaries(
        '团',
      );
      expect(singleCharacter.single.id, 'meeting');

      final defaults = await service.retrieveRelevantPreferences('发布计划');
      expect(defaults.single.text, '详细说明发布计划');
    },
  );

  test(
    'returns empty lists for empty queries, missing terms, and zero budgets',
    () async {
      await memory.saveMemorySummaries(MemorySummaryBucket.recent, [
        _summary('dart', 'Use Dart here', DateTime.now()),
      ]);
      await preference.addTexts(
        userId: service.defaultUserId,
        texts: const ['Use Dart for kernel changes'],
      );

      for (final instruction in ['   ', '！？', 'Python']) {
        final context = await service.retrieveRelevantContext(instruction);
        expect(context.memorySummaries, isEmpty);
        expect(context.preferences, isEmpty);
      }
      final limited = await service.retrieveRelevantContext(
        'Dart',
        memoryLimit: 0,
        preferenceCandidateLimit: 0,
      );
      expect(limited.memorySummaries, isEmpty);
      expect(limited.preferences, isEmpty);
    },
  );
}

MemorySummary _summary(
  String id,
  String text,
  DateTime updatedAt, {
  MemorySummaryBucket bucket = MemorySummaryBucket.recent,
}) {
  return MemorySummary(
    id: id,
    text: text,
    sourceIds: const [],
    sourceStartAt: updatedAt,
    sourceEndAt: updatedAt,
    updatedAt: updatedAt,
    bucket: bucket,
  );
}
