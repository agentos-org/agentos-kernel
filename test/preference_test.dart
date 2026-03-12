import 'dart:io';

import 'package:agentos_kernel/src/kernel/preference/hive_preference.dart';
import 'package:agentos_kernel/src/kernel/preference/model.dart';
import 'package:agentos_kernel/src/kernel/preference/vector_store.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';

void main() {
  group('HivePreference.deletePreferenceKey', () {
    test('removes associated signals and vector segments', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'hive-preference-test-',
      );
      Hive.init(tempDir.path);
      final box = await Hive.openBox<Map>('preferences');
      addTearDown(() async {
        await box.close();
        await Hive.deleteBoxFromDisk('preferences');
        await tempDir.delete(recursive: true);
      });

      final vectorStore = _FakeTextQueryVectorStore();
      final preference = HivePreference(box: box, vectorStore: vectorStore);

      await preference.recordSignal(
        PreferenceSignal(
          userId: 'u1',
          text: 'Prefer concise replies',
          metadata: const {'preferenceKey': 'responseStyle'},
        ),
      );
      await preference.recordSignal(
        PreferenceSignal(
          userId: 'u1',
          text: 'Use Chinese by default',
          metadata: const {
            'preferenceKeys': ['language'],
          },
        ),
      );

      await box.put('u1', {
        'preferences': {'responseStyle': 'concise', 'language': 'zh-CN'},
        'signals': box.get('u1')?['signals'],
      });

      await preference.deletePreferenceKey('responseStyle', userId: 'u1');

      final record = box.get('u1');
      final preferences = Map<String, dynamic>.from(
        (record?['preferences'] as Map?) ?? const {},
      );
      final signals = (record?['signals'] as List?) ?? const [];

      expect(preferences.containsKey('responseStyle'), isFalse);
      expect(preferences['language'], 'zh-CN');
      expect(signals, hasLength(1));
      expect(((signals.single as Map)['metadata'] as Map)['preferenceKeys'], [
        'language',
      ]);
      expect(vectorStore.deletedIds, hasLength(1));
      expect(vectorStore.deletedIds.single, vectorStore.upsertedIds.first);
    });

    test('keeps multi-key signal until all linked keys are removed', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'hive-preference-test-',
      );
      Hive.init(tempDir.path);
      final box = await Hive.openBox<Map>('preferences-multi');
      addTearDown(() async {
        await box.close();
        await Hive.deleteBoxFromDisk('preferences-multi');
        await tempDir.delete(recursive: true);
      });

      final vectorStore = _FakeTextQueryVectorStore();
      final preference = HivePreference(box: box, vectorStore: vectorStore);

      await preference.recordSignal(
        PreferenceSignal(
          userId: 'u1',
          text: 'Use concise Chinese replies',
          metadata: const {
            'preferenceKeys': ['responseStyle', 'language'],
          },
        ),
      );

      await box.put('u1', {
        'preferences': {'responseStyle': 'concise', 'language': 'zh-CN'},
        'signals': box.get('u1')?['signals'],
      });

      await preference.deletePreferenceKey('responseStyle', userId: 'u1');

      var record = box.get('u1');
      var signals = (record?['signals'] as List?) ?? const [];
      expect(signals, hasLength(1));
      expect(((signals.single as Map)['metadata'] as Map)['preferenceKeys'], [
        'language',
      ]);
      expect(vectorStore.deletedIds, isEmpty);

      await preference.deletePreferenceKey('language', userId: 'u1');

      record = box.get('u1');
      signals = (record?['signals'] as List?) ?? const [];
      expect(signals, isEmpty);
      expect(vectorStore.deletedIds, hasLength(1));
      expect(vectorStore.deletedIds.single, vectorStore.upsertedIds.single);
    });
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
