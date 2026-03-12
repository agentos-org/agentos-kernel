import 'model.dart';

abstract class Preference {
  Future<PreferenceSnapshot> getSnapshot({String? userId});
  Future<void> recordSignal(PreferenceSignal signal);
  Future<Map<String, dynamic>> listPreferences({String? userId});
  Future<void> deletePreferenceKey(String key, {String? userId});
}

class InMemoryPreference extends Preference {
  final Map<String, Map<String, dynamic>> _preferences = {};

  @override
  Future<PreferenceSnapshot> getSnapshot({String? userId}) async {
    return PreferenceSnapshot(
      userId: userId,
      preferences: userId == null ? const {} : _preferences[userId] ?? const {},
    );
  }

  @override
  Future<void> recordSignal(PreferenceSignal signal) async {
    final prefs = _preferences.putIfAbsent(
      signal.userId,
      () => <String, dynamic>{},
    );
    final signals =
        (prefs['signals'] as List<dynamic>?)?.toList() ?? <dynamic>[];
    signals.add({
      'text': signal.text,
      'embedding': signal.embedding,
      'metadata': signal.metadata,
      'timestamp': signal.timestamp,
    });
    prefs['signals'] = signals;
  }

  @override
  Future<Map<String, dynamic>> listPreferences({String? userId}) async {
    if (userId == null) {
      return const {};
    }
    return Map<String, dynamic>.from(_preferences[userId] ?? const {});
  }

  @override
  Future<void> deletePreferenceKey(String key, {String? userId}) async {
    if (userId == null) {
      return;
    }
    final prefs = _preferences[userId];
    prefs?.remove(key);
  }
}
