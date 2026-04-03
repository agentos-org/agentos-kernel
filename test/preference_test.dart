import 'dart:io';

import 'package:agentos_kernel/src/kernel/preference/drift_preference.dart';
import 'package:agentos_kernel/src/kernel/preference/model.dart';
import 'package:agentos_kernel/src/kernel/preference/preference.dart';
import 'package:agentos_kernel/src/kernel/preference/vector_store.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryPreference', () {
    test('dedupes exact text and refreshes updatedAt', () async {
      final preference = InMemoryPreference();
      final first = DateTime(2026, 4, 3, 10, 0, 0);
      final second = DateTime(2026, 4, 3, 11, 0, 0);

      await preference.addTexts(
        userId: 'u1',
        texts: const ['Prefer concise replies'],
        updatedAt: first,
      );
      await preference.addTexts(
        userId: 'u1',
        texts: const ['Prefer concise replies'],
        updatedAt: second,
      );

      final items = await preference.listPreferences(userId: 'u1');
      expect(items, hasLength(1));
      expect(items.single.text, 'Prefer concise replies');
      expect(items.single.updatedAt, second);
    });

    test('deletes by id', () async {
      final preference = InMemoryPreference();
      await preference.addTexts(
        userId: 'u1',
        texts: const ['Use Chinese by default'],
      );

      final items = await preference.listPreferences(userId: 'u1');
      await preference.deletePreference(items.single.id, userId: 'u1');

      expect(await preference.listPreferences(userId: 'u1'), isEmpty);
    });
  });

  group('DriftPreference', () {
    test('persists preferences across reopen', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'drift-preference-test-',
      );
      final dbPath = '${tempDir.path}/preferences.sqlite';
      addTearDown(() async {
        await tempDir.delete(recursive: true);
      });

      final vectorStore = _FakeTextQueryVectorStore();
      final first = DriftPreference.open(
        path: dbPath,
        vectorStore: vectorStore,
      );
      await first.addTexts(
        userId: 'u1',
        texts: const ['Prefer concise replies'],
        updatedAt: DateTime(2026, 4, 3, 10, 0, 0),
      );

      final second = DriftPreference.open(
        path: dbPath,
        vectorStore: vectorStore,
      );
      final items = await second.listPreferences(userId: 'u1');

      expect(items, hasLength(1));
      expect(items.single.text, 'Prefer concise replies');
    });

    test('deletes preference and removes vector segment', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'drift-preference-test-',
      );
      final dbPath = '${tempDir.path}/preferences.sqlite';
      addTearDown(() async {
        await tempDir.delete(recursive: true);
      });

      final vectorStore = _FakeTextQueryVectorStore();
      final preference = DriftPreference.open(
        path: dbPath,
        vectorStore: vectorStore,
      );
      await preference.addTexts(
        userId: 'u1',
        texts: const ['Prefer concise replies'],
      );

      final items = await preference.listPreferences(userId: 'u1');
      await preference.deletePreference(items.single.id, userId: 'u1');

      expect(await preference.listPreferences(userId: 'u1'), isEmpty);
      expect(vectorStore.deletedIds, hasLength(1));
      expect(vectorStore.deletedIds.single, vectorStore.upsertedIds.single);
    });

    test('clear removes all preferences and vector segments', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'drift-preference-test-',
      );
      final dbPath = '${tempDir.path}/preferences.sqlite';
      addTearDown(() async {
        await tempDir.delete(recursive: true);
      });

      final vectorStore = _FakeTextQueryVectorStore();
      final preference = DriftPreference.open(
        path: dbPath,
        vectorStore: vectorStore,
      );
      await preference.addTexts(
        userId: 'u1',
        texts: const ['Prefer concise replies', 'Use Chinese by default'],
      );

      await preference.clear(userId: 'u1');

      expect(await preference.listPreferences(userId: 'u1'), isEmpty);
      expect(vectorStore.deletedIds, hasLength(2));
    });
  });

  test('normalizes preference text for exact dedupe', () {
    expect(
      normalizePreferenceText('  Prefer   concise  replies  '),
      'prefer concise replies',
    );
  });
}

class _FakeTextQueryVectorStore implements TextQueryVectorStore {
  final List<String> upsertedIds = [];
  final List<String> deletedIds = [];

  @override
  Future<void> delete(String id) async {
    deletedIds.add(id);
  }

  @override
  Future<List<VectorMatch>> query({
    required List<double> vector,
    int limit = 5,
  }) async {
    return const [];
  }

  @override
  Future<List<VectorMatch>> queryByText(String text, {int limit = 5}) async {
    return const [];
  }

  @override
  Future<String> upsert({
    required String id,
    required List<double> vector,
    Map<String, dynamic>? payload,
  }) async {
    final storedId = 'segment-${upsertedIds.length + 1}';
    upsertedIds.add(storedId);
    return storedId;
  }
}
