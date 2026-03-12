import 'model.dart';

abstract class Preference {
  Future<PreferenceSnapshot> getSnapshot({String? userId});
  Future<void> recordSignal(PreferenceSignal signal);
  Future<List<PreferenceSignal>> listSignals({String? userId});
  Future<Map<String, dynamic>> listPreferences({String? userId});
  Future<void> savePreferences(
    Map<String, dynamic> preferences, {
    String? userId,
  });
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
      'userId': signal.userId,
      'text': signal.text,
      'metadata': signal.metadata,
      'timestamp': signal.timestamp,
    });
    prefs['signals'] = signals;
    prefs.putIfAbsent('preferences', () => <String, dynamic>{});
  }

  @override
  Future<List<PreferenceSignal>> listSignals({String? userId}) async {
    if (userId == null) {
      return const [];
    }
    final prefs = _preferences[userId];
    final signals = (prefs?['signals'] as List<dynamic>?) ?? const [];
    return signals
        .map(_signalFromStored)
        .whereType<PreferenceSignal>()
        .toList(growable: false);
  }

  @override
  Future<Map<String, dynamic>> listPreferences({String? userId}) async {
    if (userId == null) {
      return const {};
    }
    final prefs = _preferences[userId];
    return Map<String, dynamic>.from(
      (prefs?['preferences'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> savePreferences(
    Map<String, dynamic> preferences, {
    String? userId,
  }) async {
    if (userId == null) {
      return;
    }
    final prefs = _preferences.putIfAbsent(userId, () => <String, dynamic>{});
    prefs['preferences'] = Map<String, dynamic>.from(preferences);
  }

  @override
  Future<void> deletePreferenceKey(String key, {String? userId}) async {
    if (userId == null) {
      return;
    }
    final prefs = _preferences[userId];
    final storedPreferences = Map<String, dynamic>.from(
      (prefs?['preferences'] as Map<String, dynamic>?) ?? const {},
    );
    storedPreferences.remove(key);
    if (prefs != null) {
      prefs['preferences'] = storedPreferences;
    }
    final signals = (prefs?['signals'] as List<dynamic>?)?.toList();
    if (signals == null) {
      return;
    }
    final updatedSignals = <dynamic>[];
    for (final signal in signals) {
      final updatedSignal = _removePreferenceKeyFromSignal(signal, key);
      if (updatedSignal != null) {
        updatedSignals.add(updatedSignal);
      }
    }
    prefs!['signals'] = updatedSignals;
  }

  Map<String, dynamic>? _removePreferenceKeyFromSignal(
    Object? signal,
    String key,
  ) {
    if (signal is! Map) {
      return null;
    }
    final signalMap = Map<String, dynamic>.from(signal);
    final metadata = signalMap['metadata'];
    if (metadata is! Map<String, dynamic>) {
      return signalMap;
    }
    final nextMetadata = _removePreferenceKeyFromMetadata(metadata, key);
    if (nextMetadata == null) {
      return null;
    }
    signalMap['metadata'] = nextMetadata;
    return signalMap;
  }

  Map<String, dynamic>? _removePreferenceKeyFromMetadata(
    Map<String, dynamic> metadata,
    String key,
  ) {
    final nextMetadata = Map<String, dynamic>.from(metadata);
    final singleKey = nextMetadata['preferenceKey'];
    if (singleKey is String && singleKey.trim() == key) {
      nextMetadata.remove('preferenceKey');
    }

    final multipleKeys = nextMetadata['preferenceKeys'];
    if (multipleKeys is List) {
      final retainedKeys = multipleKeys
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty && item != key)
          .toList(growable: false);
      if (retainedKeys.isEmpty) {
        nextMetadata.remove('preferenceKeys');
      } else {
        nextMetadata['preferenceKeys'] = retainedKeys;
      }
    }

    if (preferenceSignalKeys(nextMetadata).isEmpty) {
      return null;
    }
    return nextMetadata;
  }

  PreferenceSignal? _signalFromStored(Object? signal) {
    if (signal is! Map) {
      return null;
    }
    final userId = signal['userId'];
    final text = signal['text'];
    if (userId is! String || userId.trim().isEmpty) {
      return null;
    }
    if (text is! String || text.trim().isEmpty) {
      return null;
    }
    final metadata = signal['metadata'];
    final timestamp = signal['timestamp'];
    return PreferenceSignal(
      userId: userId,
      text: text,
      metadata: metadata is Map<String, dynamic> ? metadata : null,
      timestamp: timestamp is DateTime ? timestamp : null,
    );
  }
}
