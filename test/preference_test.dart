import 'dart:io';

import 'package:agentos_kernel/src/kernel/preference/drift_preference.dart';
import 'package:agentos_kernel/src/kernel/preference/model.dart';
import 'package:agentos_kernel/src/kernel/preference/preference.dart';
import 'package:drift/native.dart';
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

      final first = DriftPreference.open(path: dbPath);
      await first.addTexts(
        userId: 'u1',
        texts: const ['Prefer concise replies'],
        updatedAt: DateTime(2026, 4, 3, 10, 0, 0),
      );

      final second = DriftPreference.open(path: dbPath);
      final items = await second.listPreferences(userId: 'u1');

      expect(items, hasLength(1));
      expect(items.single.text, 'Prefer concise replies');
    });

    test('reads and updates preferences from the previous schema', () async {
      final executor = NativeDatabase.memory(
        setup: (database) {
          database.execute('''
CREATE TABLE preference_items (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  normalized_text TEXT NOT NULL,
  text TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  index_id TEXT
);
INSERT INTO preference_items
VALUES ('legacy-id', 'u1', 'prefer concise replies', 'Prefer concise replies',
        0, 'legacy-segment');
''');
        },
      );
      addTearDown(executor.close);
      final preference = DriftPreference(executor: executor);

      final original = await preference.listPreferences(userId: 'u1');
      expect(original.single.id, 'legacy-id');

      final updatedAt = DateTime(2026, 4, 3, 11);
      final changed = await preference.addTexts(
        userId: 'u1',
        texts: const ['PREFER concise replies'],
        updatedAt: updatedAt,
      );

      expect(changed.single.id, 'legacy-id');
      final saved = await preference.listPreferences(userId: 'u1');
      expect(saved.single.id, 'legacy-id');
      expect(saved.single.text, 'PREFER concise replies');
      expect(saved.single.updatedAt, updatedAt);
    });

    test('deletes preferences only for their owner', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'drift-preference-test-',
      );
      final dbPath = '${tempDir.path}/preferences.sqlite';
      addTearDown(() async {
        await tempDir.delete(recursive: true);
      });

      final preference = DriftPreference.open(path: dbPath);
      await preference.addTexts(
        userId: 'u1',
        texts: const ['Prefer concise replies'],
      );

      final items = await preference.listPreferences(userId: 'u1');
      await preference.deletePreference(items.single.id, userId: 'u2');
      expect(await preference.listPreferences(userId: 'u1'), hasLength(1));

      await preference.deletePreference(items.single.id, userId: 'u1');
      expect(await preference.listPreferences(userId: 'u1'), isEmpty);
    });

    test("clear removes only the selected user's preferences", () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'drift-preference-test-',
      );
      final dbPath = '${tempDir.path}/preferences.sqlite';
      addTearDown(() async {
        await tempDir.delete(recursive: true);
      });

      final preference = DriftPreference.open(path: dbPath);
      await preference.addTexts(
        userId: 'u1',
        texts: const ['Prefer concise replies', 'Use Chinese by default'],
      );

      await preference.addTexts(userId: 'u2', texts: const ['Use Spanish']);
      await preference.clear(userId: 'u1');

      expect(await preference.listPreferences(userId: 'u1'), isEmpty);
      expect(await preference.listPreferences(userId: 'u2'), hasLength(1));
    });
  });

  test('normalizes preference text for exact dedupe', () {
    expect(
      normalizePreferenceText('  Prefer   concise  replies  '),
      'prefer concise replies',
    );
  });
}
