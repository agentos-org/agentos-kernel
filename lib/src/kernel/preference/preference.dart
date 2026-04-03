import 'model.dart';

abstract class Preference {
  Future<List<PreferenceEntry>> addTexts({
    required String userId,
    required List<String> texts,
    DateTime? updatedAt,
  });

  Future<List<PreferenceEntry>> listPreferences({
    String? userId,
    int offset = 0,
    int limit = 50,
  });

  Future<void> deletePreference(String id, {String? userId});

  Future<void> clear({String? userId});

  Future<void> syncIndexes({String? userId});
}

class InMemoryPreference implements Preference {
  final Map<String, List<PreferenceEntry>> _preferences = {};

  @override
  Future<List<PreferenceEntry>> addTexts({
    required String userId,
    required List<String> texts,
    DateTime? updatedAt,
  }) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return const [];
    }
    final current = _preferences.putIfAbsent(
      normalizedUserId,
      () => <PreferenceEntry>[],
    );
    final nextUpdatedAt = updatedAt ?? DateTime.now();
    final changed = <PreferenceEntry>[];
    for (final rawText in texts) {
      final normalizedText = normalizePreferenceText(rawText);
      if (normalizedText.isEmpty) {
        continue;
      }
      final existingIndex = current.indexWhere(
        (entry) => normalizePreferenceText(entry.text) == normalizedText,
      );
      if (existingIndex >= 0) {
        final existing = current[existingIndex];
        final updated = PreferenceEntry(
          id: existing.id,
          text: rawText.trim(),
          updatedAt: nextUpdatedAt,
        );
        current[existingIndex] = updated;
        changed.add(updated);
        continue;
      }
      final created = PreferenceEntry(
        id: buildPreferenceId(normalizedUserId, rawText, nextUpdatedAt),
        text: rawText.trim(),
        updatedAt: nextUpdatedAt,
      );
      current.add(created);
      changed.add(created);
    }
    return changed;
  }

  @override
  Future<List<PreferenceEntry>> listPreferences({
    String? userId,
    int offset = 0,
    int limit = 50,
  }) async {
    if (userId == null || userId.trim().isEmpty) {
      return const [];
    }
    final current = (_preferences[userId.trim()] ?? const <PreferenceEntry>[])
        .toList(growable: false);
    current.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (offset >= current.length) {
      return const [];
    }
    final paged = current.skip(offset);
    if (limit <= 0) {
      return paged.toList(growable: false);
    }
    return paged.take(limit).toList(growable: false);
  }

  @override
  Future<void> deletePreference(String id, {String? userId}) async {
    if (userId == null || userId.trim().isEmpty || id.trim().isEmpty) {
      return;
    }
    final current = _preferences[userId.trim()];
    if (current == null) {
      return;
    }
    current.removeWhere((entry) => entry.id == id);
  }

  @override
  Future<void> clear({String? userId}) async {
    if (userId == null || userId.trim().isEmpty) {
      return;
    }
    _preferences.remove(userId.trim());
  }

  @override
  Future<void> syncIndexes({String? userId}) async {}
}
