import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:lite_embeddings_sdk_dart/lite_embeddings_sdk_dart.dart'
    as embeddings;
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_daemon/opentool_daemon_client.dart';

import '../agent/model.dart';
import 'model.dart';
import 'model_profiler.dart';

abstract class Supervision {
  void onLlmEnqueued(LlmRequestMeta meta);
  void onLlmStarted(LlmRequestMeta meta);
  void onLlmFirstToken(LlmRequestMeta meta, DateTime firstTokenAt);
  void onLlmCompleted(LlmCallMetrics metrics);

  int recommendedLlmConcurrency(LlmQueueSnapshot snapshot, String modelKey);

  bool isSystemBusy();
}

class PassiveSupervision implements Supervision {
  @override
  void onLlmEnqueued(LlmRequestMeta meta) {}

  @override
  void onLlmStarted(LlmRequestMeta meta) {}

  @override
  void onLlmFirstToken(LlmRequestMeta meta, DateTime firstTokenAt) {}

  @override
  void onLlmCompleted(LlmCallMetrics metrics) {}

  @override
  int recommendedLlmConcurrency(LlmQueueSnapshot snapshot, String modelKey) =>
      1;

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
  final Map<String, _ModelHealth> _modelHealth = {};
  Map<String, KernelLlmModel> _modelCatalog = {};
  ModelProfiler? _modelProfiler;
  final Map<String, ExternalServiceHealth> _externalHealth = {};
  final List<_ExternalHealthListenerEntry> _externalHealthListeners = [];

  Timer? _eventLoopTimer;
  Duration _lastEventLoopLag = Duration.zero;
  int _lastRssBytes = 0;
  Timer? _liteAgentHealthTimer;
  Timer? _openToolHealthTimer;
  Timer? _llmHealthTimer;
  Timer? _embeddingsHealthTimer;
  LiteAgentSDK? _liteAgentSdk;
  String? _openToolHost;
  int? _openToolPort;
  String? _embeddingsBaseUrl;
  List<KernelLlmModel> _llmHealthModels = const [];
  bool _liteAgentHealthInFlight = false;
  bool _openToolHealthInFlight = false;
  bool _llmHealthInFlight = false;
  bool _embeddingsHealthInFlight = false;
  static const Duration _healthInterval = Duration(seconds: 10);
  static const Duration _healthTimeout = Duration(seconds: 3);

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

  void setModelProfiler(ModelProfiler profiler) {
    _modelProfiler = profiler;
  }

  Map<String, KernelLlmModel> get modelCatalog =>
      Map<String, KernelLlmModel>.unmodifiable(_modelCatalog);

  @override
  void onLlmCompleted(LlmCallMetrics metrics) {
    final modelKey = metrics.meta.modelKey;
    _updateModelHealth(metrics);
    _modelProfiler?.record(metrics);
    final recent = _recentByModel.putIfAbsent(
      modelKey,
      () => <LlmCallMetrics>[],
    );
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
    final limit = (_currentLimitByModel[modelKey] ?? 1).clamp(
      1,
      maxConcurrency,
    );
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
    final model = _modelCatalog[modelKey];
    if (model != null && model.source != LlmModelSource.local) {
      return;
    }
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
    final avgTtft = ttftValues.reduce((a, b) => a + b) / ttftValues.length;
    final avgTps = tpsValues.reduce((a, b) => a + b) / tpsValues.length;

    final current = _currentLimitByModel[modelKey] ?? 1;
    if (avgTtft <= ttftThreshold.inMilliseconds && avgTps >= tpsThreshold) {
      _currentLimitByModel[modelKey] = (current + 1).clamp(1, maxConcurrency);
      return;
    }
    _currentLimitByModel[modelKey] = (current / 2).ceil().clamp(
      1,
      maxConcurrency,
    );
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

  ExternalServiceHealthSnapshot externalServiceHealthSnapshot() {
    return ExternalServiceHealthSnapshot(
      items: Map<String, ExternalServiceHealth>.from(_externalHealth),
    );
  }

  ExternalServiceHealthSubscription onExternalServiceHealthChange(
    ExternalServiceHealthListener onChange,
  ) {
    final entry = _ExternalHealthListenerEntry(onChange);
    _externalHealthListeners.add(entry);
    return ExternalServiceHealthSubscription(() {
      entry.cancel();
      _externalHealthListeners.remove(entry);
    });
  }

  void startExternalServiceMonitoring({
    required LiteAgentSDK liteAgentSdk,
    String? opentoolHost,
    int? opentoolPort,
    String? embeddingsBaseUrl,
  }) {
    _liteAgentSdk = liteAgentSdk;
    _openToolHost = opentoolHost;
    _openToolPort = opentoolPort;
    _embeddingsBaseUrl = embeddingsBaseUrl;
    _ensureLiteAgentMonitor();
    _ensureOpenToolMonitor();
    _ensureEmbeddingsMonitor();
  }

  void startLlmHealthMonitoring(List<KernelLlmModel> models) {
    _llmHealthModels = List<KernelLlmModel>.from(models);
    _ensureLlmMonitor();
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
    switch (model.source) {
      case LlmModelSource.remote:
        return maxConcurrency;
      case LlmModelSource.custom:
        return (maxConcurrency / 2).ceil().clamp(1, maxConcurrency);
      case LlmModelSource.local:
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

  void _ensureLiteAgentMonitor() {
    if (_liteAgentHealthTimer != null) {
      return;
    }
    _liteAgentHealthTimer = Timer.periodic(
      _healthInterval,
      (_) => _checkLiteAgentHealth(),
    );
    unawaited(_checkLiteAgentHealth());
  }

  void _ensureOpenToolMonitor() {
    if (_openToolHealthTimer != null) {
      return;
    }
    _openToolHealthTimer = Timer.periodic(
      _healthInterval,
      (_) => _checkOpenToolHealth(),
    );
    unawaited(_checkOpenToolHealth());
  }

  void _ensureLlmMonitor() {
    if (_llmHealthTimer != null) {
      return;
    }
    _llmHealthTimer = Timer.periodic(_healthInterval, (_) => _checkLlmHealth());
    unawaited(_checkLlmHealth());
  }

  void _ensureEmbeddingsMonitor() {
    if (_embeddingsHealthTimer != null) {
      return;
    }
    _embeddingsHealthTimer = Timer.periodic(
      _healthInterval,
      (_) => _checkEmbeddingsHealth(),
    );
    unawaited(_checkEmbeddingsHealth());
  }

  Future<void> _checkLiteAgentHealth() async {
    if (_liteAgentHealthInFlight) {
      return;
    }
    final liteAgentSdk = _liteAgentSdk;
    if (liteAgentSdk == null) {
      return;
    }
    _liteAgentHealthInFlight = true;
    final id = 'liteagent';
    try {
      final version = await liteAgentSdk.getVersion();
      _recordExternalHealth(
        ExternalServiceHealth(
          id: id,
          type: ExternalServiceType.liteagent,
          available: true,
          version: version.version,
          lastSuccessAt: DateTime.now(),
        ),
      );
    } catch (error) {
      _recordExternalHealth(
        ExternalServiceHealth(
          id: id,
          type: ExternalServiceType.liteagent,
          available: false,
          lastFailureAt: DateTime.now(),
          message: error.toString(),
        ),
      );
    } finally {
      _liteAgentHealthInFlight = false;
    }
  }

  Future<void> _checkOpenToolHealth() async {
    if (_openToolHealthInFlight) {
      return;
    }
    _openToolHealthInFlight = true;
    final host = _openToolHost;
    final port = _openToolPort;
    final id = 'opentool_daemon';
    try {
      final client = DaemonClient(
        host: host ?? '127.0.0.1',
        port: port ?? DAEMON_DEFAULT_PORT,
      );
      final version = await client.getVersion();
      final endpoint = 'http://${client.host}:${client.port}${client.prefix}';
      _recordExternalHealth(
        ExternalServiceHealth(
          id: id,
          type: ExternalServiceType.opentoolDaemon,
          available: true,
          version: version.version,
          lastSuccessAt: DateTime.now(),
          endpoint: endpoint,
        ),
      );
    } catch (error) {
      _recordExternalHealth(
        ExternalServiceHealth(
          id: id,
          type: ExternalServiceType.opentoolDaemon,
          available: false,
          lastFailureAt: DateTime.now(),
          message: error.toString(),
        ),
      );
    } finally {
      _openToolHealthInFlight = false;
    }
  }

  Future<void> _checkEmbeddingsHealth() async {
    if (_embeddingsHealthInFlight) {
      return;
    }
    final baseUrl = _embeddingsBaseUrl;
    if (baseUrl == null || baseUrl.trim().isEmpty) {
      return;
    }
    _embeddingsHealthInFlight = true;
    final id = 'embeddings';
    try {
      final client = embeddings.LiteEmbeddingsClient(baseUrl: baseUrl.trim());
      final version = await client.getVersion();
      _recordExternalHealth(
        ExternalServiceHealth(
          id: id,
          type: ExternalServiceType.embeddings,
          available: true,
          version: version.version,
          lastSuccessAt: DateTime.now(),
          endpoint: baseUrl.trim(),
        ),
      );
    } catch (error) {
      _recordExternalHealth(
        ExternalServiceHealth(
          id: id,
          type: ExternalServiceType.embeddings,
          available: false,
          lastFailureAt: DateTime.now(),
          message: error.toString(),
          endpoint: baseUrl.trim(),
        ),
      );
    } finally {
      _embeddingsHealthInFlight = false;
    }
  }

  Future<void> _checkLlmHealth() async {
    if (_llmHealthInFlight) {
      return;
    }
    if (_llmHealthModels.isEmpty) {
      return;
    }
    _llmHealthInFlight = true;
    final grouped = <String, List<KernelLlmModel>>{};
    for (final model in _llmHealthModels) {
      grouped.putIfAbsent(model.baseUrl, () => []).add(model);
    }
    for (final entry in grouped.entries) {
      final baseUrl = entry.key.trim();
      final endpoint = _llmHealthEndpoint(baseUrl);
      bool ok = false;
      String? message;
      try {
        final response = await http
            .get(Uri.parse(endpoint))
            .timeout(_healthTimeout);
        ok = response.statusCode >= 200 && response.statusCode < 300;
        if (!ok) {
          message = 'HTTP ${response.statusCode}';
        }
      } catch (error) {
        message = error.toString();
      }
      for (final model in entry.value) {
        final modelKey = model.modelKey();
        _recordExternalHealth(
          ExternalServiceHealth(
            id: 'llm:$modelKey',
            type: ExternalServiceType.llm,
            available: ok,
            lastSuccessAt: ok ? DateTime.now() : null,
            lastFailureAt: ok ? null : DateTime.now(),
            message: ok ? null : message,
            endpoint: endpoint,
            modelKey: modelKey,
          ),
        );
      }
    }
    _llmHealthInFlight = false;
  }

  String _llmHealthEndpoint(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.endsWith('/')) {
      return '${trimmed}health';
    }
    return '$trimmed/health';
  }

  void _recordExternalHealth(ExternalServiceHealth health) {
    final existing = _externalHealth[health.id];
    _externalHealth[health.id] = health;
    final shouldNotify =
        existing == null ||
        existing.available != health.available ||
        existing.version != health.version ||
        existing.message != health.message ||
        existing.endpoint != health.endpoint ||
        existing.modelKey != health.modelKey;
    if (!shouldNotify) {
      return;
    }
    final listeners = List<_ExternalHealthListenerEntry>.from(
      _externalHealthListeners,
    );
    for (final entry in listeners) {
      entry.emit(health);
      if (!entry.active) {
        _externalHealthListeners.remove(entry);
      }
    }
  }
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

class _ModelHealth {
  int consecutiveFailures = 0;
  DateTime? cooldownUntil;
  DateTime? lastFailureAt;
  DateTime? lastSuccessAt;
}

class _ExternalHealthListenerEntry {
  final ExternalServiceHealthListener _listener;
  bool active = true;

  _ExternalHealthListenerEntry(this._listener);

  void emit(ExternalServiceHealth health) {
    if (!active) {
      return;
    }
    _listener(health);
  }

  void cancel() {
    active = false;
  }
}
