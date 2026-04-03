import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../agent/model.dart';

class ModelPurposeStats {
  int totalCalls;
  int successCount;
  int failureCount;

  ModelPurposeStats({
    this.totalCalls = 0,
    this.successCount = 0,
    this.failureCount = 0,
  });

  double get successRate => totalCalls == 0 ? 0.0 : successCount / totalCalls;

  Map<String, dynamic> toMap() => {
    'totalCalls': totalCalls,
    'successCount': successCount,
    'failureCount': failureCount,
  };

  factory ModelPurposeStats.fromMap(Map<String, dynamic> map) =>
      ModelPurposeStats(
        totalCalls: map['totalCalls'] as int? ?? 0,
        successCount: map['successCount'] as int? ?? 0,
        failureCount: map['failureCount'] as int? ?? 0,
      );
}

class ModelProfile {
  int totalCalls;
  int successCount;
  int failureCount;
  double avgTtftMs;
  double avgTps;
  int maxSuccessTokens;
  final Map<String, ModelPurposeStats> purposeStats;

  ModelProfile({
    this.totalCalls = 0,
    this.successCount = 0,
    this.failureCount = 0,
    this.avgTtftMs = 0.0,
    this.avgTps = 0.0,
    this.maxSuccessTokens = 0,
    Map<String, ModelPurposeStats>? purposeStats,
  }) : purposeStats = purposeStats ?? {};

  double get overallSuccessRate =>
      totalCalls == 0 ? 0.0 : successCount / totalCalls;

  double purposeSuccessRate(String purpose) {
    final stats = purposeStats[purpose];
    if (stats == null) return 0.0;
    return stats.successRate;
  }

  int purposeTotalCalls(String purpose) {
    return purposeStats[purpose]?.totalCalls ?? 0;
  }

  Map<String, dynamic> toMap() => {
    'totalCalls': totalCalls,
    'successCount': successCount,
    'failureCount': failureCount,
    'avgTtftMs': avgTtftMs,
    'avgTps': avgTps,
    'maxSuccessTokens': maxSuccessTokens,
    'purposeStats': purposeStats.map(
      (key, value) => MapEntry(key, value.toMap()),
    ),
  };

  factory ModelProfile.fromMap(Map<String, dynamic> map) {
    final rawPurpose = map['purposeStats'];
    final purposeStats = <String, ModelPurposeStats>{};
    if (rawPurpose is Map) {
      rawPurpose.forEach((key, value) {
        if (value is Map) {
          purposeStats[key.toString()] = ModelPurposeStats.fromMap(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    return ModelProfile(
      totalCalls: map['totalCalls'] as int? ?? 0,
      successCount: map['successCount'] as int? ?? 0,
      failureCount: map['failureCount'] as int? ?? 0,
      avgTtftMs: (map['avgTtftMs'] as num?)?.toDouble() ?? 0.0,
      avgTps: (map['avgTps'] as num?)?.toDouble() ?? 0.0,
      maxSuccessTokens: map['maxSuccessTokens'] as int? ?? 0,
      purposeStats: purposeStats,
    );
  }
}

class ModelProfiler {
  final QueryExecutor? _executor;
  final _ModelProfilerDbUser? _user;
  Future<void>? _openFuture;
  final Map<String, ModelProfile> _profiles = {};
  static const int _explorationThreshold = 10;

  ModelProfiler() : _executor = null, _user = null;

  ModelProfiler._(this._executor, this._user);

  static Future<ModelProfiler> open({required String path}) async {
    final profiler = ModelProfiler._(
      _openConnection(path),
      _ModelProfilerDbUser(),
    );
    await profiler._ensureOpen();
    await profiler._loadFromDb();
    return profiler;
  }

  Future<void> _ensureOpen() {
    final executor = _executor;
    final user = _user;
    if (executor == null || user == null) {
      return Future.value();
    }
    _openFuture ??= () async {
      await executor.ensureOpen(user);
      await user.ensureInitialized(executor);
    }();
    return _openFuture!;
  }

  Future<void> _loadFromDb() async {
    final executor = _executor;
    if (executor == null) {
      return;
    }
    final rows = await executor.runSelect('''
SELECT model_key, profile_json
FROM model_profiles;
''', const []);
    _profiles.clear();
    for (final row in rows) {
      final modelKey = row['model_key'] as String?;
      final raw = row['profile_json'] as String?;
      if (modelKey == null || modelKey.trim().isEmpty || raw == null) {
        continue;
      }
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _profiles[modelKey] = ModelProfile.fromMap(decoded);
        } else if (decoded is Map) {
          _profiles[modelKey] = ModelProfile.fromMap(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {}
    }
  }

  void record(LlmCallMetrics metrics) {
    final modelKey = metrics.meta.modelKey;
    final purpose = metrics.meta.purpose;
    final profile = _profiles.putIfAbsent(modelKey, () => ModelProfile());

    profile.totalCalls += 1;
    final purposeEntry = profile.purposeStats.putIfAbsent(
      purpose,
      () => ModelPurposeStats(),
    );
    purposeEntry.totalCalls += 1;

    if (metrics.success) {
      profile.successCount += 1;
      purposeEntry.successCount += 1;
      final tokens = metrics.totalTokens;
      if (tokens != null && tokens > profile.maxSuccessTokens) {
        profile.maxSuccessTokens = tokens;
      }
    } else {
      profile.failureCount += 1;
      purposeEntry.failureCount += 1;
    }

    final ttftMs = metrics.ttft?.inMilliseconds;
    if (ttftMs != null) {
      profile.avgTtftMs = _runningAvg(
        profile.avgTtftMs,
        ttftMs.toDouble(),
        profile.totalCalls,
      );
    }

    final tps = metrics.tps;
    if (tps != null) {
      profile.avgTps = _runningAvg(profile.avgTps, tps, profile.totalCalls);
    }

    unawaited(_persist(modelKey, profile));
  }

  ModelProfile? getProfile(String modelKey) => _profiles[modelKey];

  bool shouldSkip({
    required String modelKey,
    required String purpose,
    required double successRateThreshold,
  }) {
    final profile = _profiles[modelKey];
    if (profile == null) return false;
    if (profile.purposeTotalCalls(purpose) < _explorationThreshold) {
      return false;
    }
    return profile.purposeSuccessRate(purpose) < successRateThreshold;
  }

  double rankScore(String modelKey, String purpose) {
    final profile = _profiles[modelKey];
    if (profile == null) return 0.5;
    if (profile.purposeTotalCalls(purpose) < _explorationThreshold) {
      return 0.5;
    }
    return profile.purposeSuccessRate(purpose);
  }

  Map<String, ModelProfile> get profiles =>
      Map<String, ModelProfile>.unmodifiable(_profiles);

  double _runningAvg(double currentAvg, double newValue, int totalCount) {
    if (totalCount <= 1) return newValue;
    return currentAvg + (newValue - currentAvg) / totalCount;
  }

  Future<void> _persist(String modelKey, ModelProfile profile) async {
    final executor = _executor;
    if (executor == null) {
      return;
    }
    await _ensureOpen();
    await executor.runCustom(
      '''
INSERT INTO model_profiles (model_key, profile_json)
VALUES (?, ?)
ON CONFLICT(model_key) DO UPDATE SET profile_json = excluded.profile_json;
''',
      [modelKey, jsonEncode(profile.toMap())],
    );
  }
}

class _ModelProfilerDbUser implements QueryExecutorUser {
  Future<void>? _initFuture;

  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}

  Future<void> ensureInitialized(QueryExecutor executor) {
    _initFuture ??= _createSchema(executor);
    return _initFuture!;
  }

  Future<void> _createSchema(QueryExecutor executor) async {
    await executor.runCustom('''
CREATE TABLE IF NOT EXISTS model_profiles (
  model_key TEXT PRIMARY KEY,
  profile_json TEXT NOT NULL
);
''');
  }
}

QueryExecutor _openConnection(String path) {
  return LazyDatabase(() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return NativeDatabase(file);
  });
}
