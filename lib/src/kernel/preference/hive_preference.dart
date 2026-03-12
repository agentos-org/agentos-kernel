import 'package:hive/hive.dart';

import 'embedder.dart';
import 'model.dart';
import 'preference.dart';
import 'vector_store.dart';

class HivePreference implements Preference {
  final Box<Map> _box;
  final VectorStore _vectorStore;
  final PreferenceEmbedder _embedder;
  final int signalRetention;

  HivePreference({
    required Box<Map> box,
    required VectorStore vectorStore,
    PreferenceEmbedder? embedder,
    this.signalRetention = 50,
  }) : _box = box,
       _vectorStore = vectorStore,
       _embedder = embedder ?? HashEmbedder();

  @override
  Future<PreferenceSnapshot> getSnapshot({String? userId}) async {
    if (userId == null) {
      return const PreferenceSnapshot();
    }
    final record = _box.get(userId);
    final preferences =
        (record?['preferences'] as Map<String, dynamic>?) ?? const {};
    return PreferenceSnapshot(userId: userId, preferences: preferences);
  }

  @override
  Future<void> recordSignal(PreferenceSignal signal) async {
    final record = _box.get(signal.userId) ?? <String, dynamic>{};
    final signals =
        (record['signals'] as List<dynamic>?)?.toList() ?? <dynamic>[];
    final embedding = _embedder.embed(signal.text);
    final indexId = await _vectorStore.upsert(
      id: '${signal.userId}-${signal.timestamp.microsecondsSinceEpoch}',
      vector: embedding,
      payload: {
        'userId': signal.userId,
        'text': signal.text,
        'metadata': signal.metadata,
        'timestamp': signal.timestamp.toIso8601String(),
      },
    );
    signals.add(_signalToMap(signal, indexId: indexId));
    if (signals.length > signalRetention) {
      final removed = signals.removeAt(0);
      await _deleteIndexedSignal(removed);
    }
    record['signals'] = signals;
    record.putIfAbsent('preferences', () => <String, dynamic>{});
    await _box.put(signal.userId, record);
  }

  @override
  Future<Map<String, dynamic>> listPreferences({String? userId}) async {
    if (userId == null) {
      return const {};
    }
    final record = _box.get(userId);
    return Map<String, dynamic>.from(
      (record?['preferences'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> deletePreferenceKey(String key, {String? userId}) async {
    if (userId == null || key.trim().isEmpty) {
      return;
    }
    final record = _box.get(userId);
    if (record == null) {
      return;
    }
    final preferences = Map<String, dynamic>.from(
      (record['preferences'] as Map<String, dynamic>?) ?? const {},
    );
    if (!preferences.containsKey(key)) {
      return;
    }
    final signals =
        (record['signals'] as List<dynamic>?)?.toList() ?? <dynamic>[];
    final retainedSignals = <dynamic>[];
    final removedSignals = <dynamic>[];
    for (final signal in signals) {
      final updatedSignal = _removePreferenceKeyFromSignal(signal, key);
      if (updatedSignal == null) {
        removedSignals.add(signal);
      } else {
        retainedSignals.add(updatedSignal);
      }
    }
    for (final signal in removedSignals) {
      await _deleteIndexedSignal(signal);
    }
    preferences.remove(key);
    record['preferences'] = preferences;
    record['signals'] = retainedSignals;
    await _box.put(userId, record);
  }

  Map<String, dynamic> _signalToMap(
    PreferenceSignal signal, {
    String? indexId,
  }) {
    return {
      'userId': signal.userId,
      'text': signal.text,
      'metadata': signal.metadata,
      'timestamp': signal.timestamp,
      if (indexId != null) 'indexId': indexId,
    };
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

  Future<void> _deleteIndexedSignal(Object? signal) async {
    if (signal is! Map) {
      return;
    }
    final indexId = signal['indexId'];
    if (indexId is String && indexId.trim().isNotEmpty) {
      await _vectorStore.delete(indexId);
    }
  }
}
