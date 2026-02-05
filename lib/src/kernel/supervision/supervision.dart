import 'dart:async';
import 'dart:io';

import '../events.dart';
import '../agent/model.dart';
import 'model.dart';

abstract class Supervision {
  SupervisionAdvice? observe(KernelEvent event);

  void onLlmEnqueued(LlmRequestMeta meta);
  void onLlmStarted(LlmRequestMeta meta);
  void onLlmFirstToken(LlmRequestMeta meta, DateTime firstTokenAt);
  void onLlmCompleted(LlmCallMetrics metrics);

  int recommendedLlmConcurrency(LlmQueueSnapshot snapshot, String modelKey);

  bool isSystemBusy();
}

class PassiveSupervision implements Supervision {
  @override
  SupervisionAdvice? observe(KernelEvent event) {
    return null;
  }

  @override
  void onLlmEnqueued(LlmRequestMeta meta) {}

  @override
  void onLlmStarted(LlmRequestMeta meta) {}

  @override
  void onLlmFirstToken(LlmRequestMeta meta, DateTime firstTokenAt) {}

  @override
  void onLlmCompleted(LlmCallMetrics metrics) {}

  @override
  int recommendedLlmConcurrency(LlmQueueSnapshot snapshot, String modelKey) => 1;

  @override
  bool isSystemBusy() => false;
}

class AdaptiveSupervision implements Supervision {
  final Duration ttftThreshold;
  final double tpsThreshold;
  final int maxConcurrency;
  final int windowSize;
  final Duration eventLoopLagThreshold;
  final Duration eventLoopSampleInterval;
  final int rssThresholdBytes;
  final int modelFailureThreshold;
  final Duration modelCooldownDuration;
  final double largeModelParamsBThreshold;
  final double mediumModelParamsBThreshold;
  final double largeModelSizeGbThreshold;
  final double mediumModelSizeGbThreshold;

  final Map<String, int> _currentLimitByModel = {};
  final Map<String, List<LlmCallMetrics>> _recentByModel = {};
  final Map<String, Set<String>> _generatingByModel = {};
  final Set<String> _inFlight = {};
  final Map<String, _ToolStats> _toolStats = {};
  final Map<String, _ModelHealth> _modelHealth = {};
  Map<String, KernelLlmModel> _modelCatalog = {};

  Timer? _eventLoopTimer;
  Duration _lastEventLoopLag = Duration.zero;
  int _lastRssBytes = 0;

  AdaptiveSupervision({
    required this.ttftThreshold,
    required this.tpsThreshold,
    this.maxConcurrency = 8,
    this.windowSize = 10,
    this.eventLoopLagThreshold = const Duration(milliseconds: 120),
    this.eventLoopSampleInterval = const Duration(milliseconds: 500),
    this.rssThresholdBytes = 1536 * 1024 * 1024,
    this.modelFailureThreshold = 3,
    this.modelCooldownDuration = const Duration(seconds: 30),
    this.largeModelParamsBThreshold = 30,
    this.mediumModelParamsBThreshold = 13,
    this.largeModelSizeGbThreshold = 20,
    this.mediumModelSizeGbThreshold = 10,
  });

  @override
  SupervisionAdvice? observe(KernelEvent event) {
    if (event is ToolCallStartedEvent) {
      _toolStats
          .putIfAbsent(event.toolId, () => _ToolStats())
          .onStart();
    } else if (event is ToolCallDoneEvent) {
      final duration =
          event.completedAt.difference(event.startedAt).inMilliseconds;
      _toolStats
          .putIfAbsent(event.toolId, () => _ToolStats())
          .onSuccess(duration);
    } else if (event is ToolCallFailedEvent) {
      final duration =
          event.completedAt.difference(event.startedAt).inMilliseconds;
      _toolStats
          .putIfAbsent(event.toolId, () => _ToolStats())
          .onFailure(duration, event.error);
    }
    return null;
  }

  @override
  void onLlmEnqueued(LlmRequestMeta meta) {}

  @override
  void onLlmStarted(LlmRequestMeta meta) {
    _inFlight.add(meta.id);
    _generatingByModel.putIfAbsent(meta.modelKey, () => <String>{});
  }

  @override
  void onLlmFirstToken(LlmRequestMeta meta, DateTime firstTokenAt) {
    _generatingByModel
        .putIfAbsent(meta.modelKey, () => <String>{})
        .add(meta.id);
  }

  @override
  void onLlmCompleted(LlmCallMetrics metrics) {
    final modelKey = metrics.meta.modelKey;
    _updateModelHealth(metrics);
    final recent = _recentByModel.putIfAbsent(modelKey, () => <LlmCallMetrics>[]);
    recent.add(metrics);
    if (recent.length > windowSize) {
      recent.removeAt(0);
    }
    _generatingByModel[modelKey]?.remove(metrics.meta.id);
    _inFlight.remove(metrics.meta.id);
    _adjustConcurrency(modelKey);
  }

  @override
  int recommendedLlmConcurrency(LlmQueueSnapshot snapshot, String modelKey) {
    if (!_isModelAvailable(modelKey)) {
      return 0;
    }
    final limit =
        (_currentLimitByModel[modelKey] ?? 1).clamp(1, maxConcurrency);
    final cap = _modelConcurrencyCap(modelKey);
    if (snapshot.inFlight == 0) {
      return _applyConcurrencyCap(limit, cap);
    }
    final generating = _generatingByModel[modelKey];
    if (generating == null || generating.isEmpty) {
      return _applyConcurrencyCap((limit + 1).clamp(1, maxConcurrency), cap);
    }
    return _applyConcurrencyCap(limit, cap);
  }

  void _adjustConcurrency(String modelKey) {
    final recent = _recentByModel[modelKey];
    if (recent == null || recent.isEmpty) {
      return;
    }
    final ttftValues = recent
        .map((metric) => metric.ttft?.inMilliseconds)
        .whereType<int>()
        .toList();
    final tpsValues = recent
        .map((metric) => metric.tps)
        .whereType<double>()
        .toList();
    if (ttftValues.isEmpty || tpsValues.isEmpty) {
      return;
    }
    final avgTtft =
        ttftValues.reduce((a, b) => a + b) / ttftValues.length;
    final avgTps = tpsValues.reduce((a, b) => a + b) / tpsValues.length;

    final current = _currentLimitByModel[modelKey] ?? 1;
    if (avgTtft <= ttftThreshold.inMilliseconds && avgTps >= tpsThreshold) {
      _currentLimitByModel[modelKey] = (current + 1).clamp(1, maxConcurrency);
      return;
    }
    _currentLimitByModel[modelKey] =
        (current / 2).ceil().clamp(1, maxConcurrency);
  }

  Map<String, ToolStatsSnapshot> toolStatsSnapshot() {
    final snapshot = <String, ToolStatsSnapshot>{};
    _toolStats.forEach((key, stats) {
      snapshot[key] = stats.toSnapshot();
    });
    return snapshot;
  }

  Map<String, ModelHealthSnapshot> modelHealthSnapshot() {
    final snapshot = <String, ModelHealthSnapshot>{};
    _modelHealth.forEach((key, health) {
      snapshot[key] = ModelHealthSnapshot(
        available: _isModelAvailable(key),
        consecutiveFailures: health.consecutiveFailures,
        cooldownUntil: health.cooldownUntil,
        lastFailureAt: health.lastFailureAt,
        lastSuccessAt: health.lastSuccessAt,
      );
    });
    return snapshot;
  }

  @override
  bool isSystemBusy() {
    _ensureEventLoopProbe();
    final llmBusy = _inFlight.isNotEmpty;
    final lagBusy = _lastEventLoopLag > eventLoopLagThreshold;
    final rssBusy = _lastRssBytes > rssThresholdBytes;
    return llmBusy || lagBusy || rssBusy;
  }

  void _updateModelHealth(LlmCallMetrics metrics) {
    if (modelFailureThreshold <= 0) {
      return;
    }
    final modelKey = metrics.meta.modelKey;
    final health = _modelHealth.putIfAbsent(modelKey, () => _ModelHealth());
    if (metrics.success) {
      health.consecutiveFailures = 0;
      health.lastSuccessAt = metrics.doneAt;
      if (health.cooldownUntil != null &&
          DateTime.now().isAfter(health.cooldownUntil!)) {
        health.cooldownUntil = null;
      }
      return;
    }
    health.consecutiveFailures += 1;
    health.lastFailureAt = metrics.doneAt;
    if (health.consecutiveFailures >= modelFailureThreshold) {
      health.cooldownUntil = metrics.doneAt.add(modelCooldownDuration);
    }
  }

  bool _isModelAvailable(String modelKey) {
    final health = _modelHealth[modelKey];
    if (health == null) {
      return true;
    }
    final cooldownUntil = health.cooldownUntil;
    if (cooldownUntil == null) {
      return true;
    }
    if (DateTime.now().isAfter(cooldownUntil)) {
      health.cooldownUntil = null;
      health.consecutiveFailures = 0;
      return true;
    }
    return false;
  }

  void updateModelCatalog(List<KernelLlmModel> models) {
    final catalog = <String, KernelLlmModel>{};
    for (final model in models) {
      final key = model.modelKey();
      catalog[key] = model;
    }
    _modelCatalog = catalog;
  }

  int _modelConcurrencyCap(String modelKey) {
    final model = _modelCatalog[modelKey];
    if (model == null) {
      return maxConcurrency;
    }
    if (model.paramsB >= largeModelParamsBThreshold ||
        model.sizeGB >= largeModelSizeGbThreshold) {
      return 1;
    }
    if (model.paramsB >= mediumModelParamsBThreshold ||
        model.sizeGB >= mediumModelSizeGbThreshold) {
      return (maxConcurrency / 2).ceil().clamp(1, maxConcurrency);
    }
    return maxConcurrency;
  }

  int _applyConcurrencyCap(int limit, int cap) {
    if (cap <= 0) {
      return 0;
    }
    return limit > cap ? cap : limit;
  }

  void _ensureEventLoopProbe() {
    if (_eventLoopTimer != null) {
      return;
    }
    var lastTick = DateTime.now();
    _eventLoopTimer = Timer.periodic(eventLoopSampleInterval, (_) {
      final now = DateTime.now();
      final elapsed = now.difference(lastTick);
      final lag = elapsed - eventLoopSampleInterval;
      _lastEventLoopLag = lag.isNegative ? Duration.zero : lag;
      lastTick = now;
      _lastRssBytes = ProcessInfo.currentRss;
    });
  }
}

class ToolStatsSnapshot {
  final int started;
  final int success;
  final int failed;
  final double? avgDurationMs;
  final Map<String, int> errorCounts;

  const ToolStatsSnapshot({
    required this.started,
    required this.success,
    required this.failed,
    required this.avgDurationMs,
    required this.errorCounts,
  });
}

class ModelHealthSnapshot {
  final bool available;
  final int consecutiveFailures;
  final DateTime? cooldownUntil;
  final DateTime? lastFailureAt;
  final DateTime? lastSuccessAt;

  const ModelHealthSnapshot({
    required this.available,
    required this.consecutiveFailures,
    required this.cooldownUntil,
    required this.lastFailureAt,
    required this.lastSuccessAt,
  });
}

class _ToolStats {
  int started = 0;
  int success = 0;
  int failed = 0;
  int _durationTotal = 0;
  int _durationCount = 0;
  final Map<String, int> errorCounts = {};

  void onStart() {
    started += 1;
  }

  void onSuccess(int durationMs) {
    success += 1;
    _durationTotal += durationMs;
    _durationCount += 1;
  }

  void onFailure(int durationMs, String error) {
    failed += 1;
    _durationTotal += durationMs;
    _durationCount += 1;
    errorCounts.update(error, (count) => count + 1, ifAbsent: () => 1);
  }

  ToolStatsSnapshot toSnapshot() {
    final avgDuration = _durationCount == 0
        ? null
        : _durationTotal / _durationCount;
    return ToolStatsSnapshot(
      started: started,
      success: success,
      failed: failed,
      avgDurationMs: avgDuration,
      errorCounts: Map<String, int>.from(errorCounts),
    );
  }
}

class _ModelHealth {
  int consecutiveFailures = 0;
  DateTime? cooldownUntil;
  DateTime? lastFailureAt;
  DateTime? lastSuccessAt;
}
