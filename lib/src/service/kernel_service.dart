import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_daemon/opentool_daemon_client.dart';
import 'package:opentool_dart/opentool_client.dart';

import '../kernel/opentool/opentool_daemon_registry.dart';
import '../kernel/cron/daemon_open_spec_provider.dart';
import '../kernel/cron/llm_config_access.dart';
import '../kernel/cron/agent_executor.dart';
import '../kernel/cron/model.dart';
import '../kernel/cron/module.dart';
import '../kernel/cron/store.dart';
import '../kernel/kernel.dart';
import '../kernel/agent/liteagent_client.dart';
import '../kernel/agent/llm_metrics.dart';
import '../kernel/agent/llm_queue.dart';
import '../kernel/agent/config.dart';
import '../kernel/agent/model.dart';
import '../kernel/logging/logger.dart';
import '../kernel/memory/drift_memory.dart';
import '../kernel/memory/memory_pipeline.dart';
import '../kernel/memory/memory_summarizer.dart';
import '../kernel/memory/model.dart';
import '../kernel/preference/model.dart';
import '../kernel/preference/drift_preference.dart';
import '../kernel/preference/preference.dart';
import '../kernel/preference/preference_extractor.dart';
import '../kernel/preference/agent_preference_extractor.dart';
import '../kernel/preference/preference_processor.dart';
import '../kernel/supervision/model.dart';
import '../kernel/supervision/model_profiler.dart';
import '../kernel/supervision/supervision.dart';
import 'dto.dart';
import 'kernel_admin_service.dart';
import 'model.dart';

class LlmConfigGroup {
  final List<KernelLlmModel> models;

  const LlmConfigGroup({required this.models});
}

class KernelRuntimeConfig {
  final String? memoryDbPath;
  final String? preferenceDbPath;
  final String? modelProfilerDbPath;
  final String? cronDbPath;
  final Duration ttftThreshold;
  final double tpsThreshold;
  final int maxConcurrency;
  final Duration memorySummaryRecentWindow;
  final int memorySummaryMaxRecords;
  final int memorySummaryMinRecords;
  final bool memorySummaryEnabled;
  final Duration memorySummaryInterval;
  final Duration memorySummaryTaskTimeout;
  final int memorySummaryMaxScopesPerRun;
  final bool preferenceExtractionEnabled;
  final Duration preferenceExtractionInterval;
  final Duration preferenceExtractionTaskTimeout;
  final int preferenceExtractionMaxPerRun;
  final int preferenceExtractionMinRecords;
  final int preferenceExtractionQueueLimit;
  final String opentoolDaemonHost;
  final int opentoolDaemonPort;
  final KernelMode mode;
  final double profileSuccessRateThreshold;

  const KernelRuntimeConfig({
    this.memoryDbPath = '.hive/kernel_memory.sqlite',
    this.preferenceDbPath = '.hive/kernel_preference.sqlite',
    this.modelProfilerDbPath = '.hive/kernel_model_profiles.sqlite',
    this.cronDbPath = '.hive/kernel_cron.sqlite',
    this.ttftThreshold = const Duration(milliseconds: 5000),
    this.tpsThreshold = 5.0,
    this.maxConcurrency = 8,
    this.memorySummaryRecentWindow = const Duration(hours: 24),
    this.memorySummaryMaxRecords = 200,
    this.memorySummaryMinRecords = 20,
    // Temporarily opt in while background memory summarization is not needed.
    this.memorySummaryEnabled = false,
    this.memorySummaryInterval = const Duration(minutes: 30),
    this.memorySummaryTaskTimeout = const Duration(minutes: 2),
    this.memorySummaryMaxScopesPerRun = 1,
    // Temporarily opt in while background preference extraction is not needed.
    this.preferenceExtractionEnabled = false,
    this.preferenceExtractionInterval = const Duration(minutes: 10),
    this.preferenceExtractionTaskTimeout = const Duration(minutes: 2),
    this.preferenceExtractionMaxPerRun = 1,
    this.preferenceExtractionMinRecords = 3,
    this.preferenceExtractionQueueLimit = 200,
    this.opentoolDaemonHost = '127.0.0.1',
    this.opentoolDaemonPort = DAEMON_DEFAULT_PORT,
    this.mode = KernelMode.balanced,
    this.profileSuccessRateThreshold = 0.4,
  });
}

class KernelServiceConfig {
  final LiteAgentSDK liteAgentSdk;
  final List<PresetOpenSpec>? presetOpenSpecList;
  final LlmConfigGroup? llm;
  final List<String>? preferenceSkills;
  final KernelRuntimeConfig runtime;

  const KernelServiceConfig({
    required this.liteAgentSdk,
    this.presetOpenSpecList,
    this.llm,
    this.preferenceSkills,
    this.runtime = const KernelRuntimeConfig(),
  });
}

class KernelReadiness {
  final bool ready;
  final bool llmConfigured;
  final bool llmServicesReady;
  final bool liteAgentReady;
  final bool openToolDaemonReady;
  final List<String> reasons;

  const KernelReadiness({
    required this.ready,
    required this.llmConfigured,
    required this.llmServicesReady,
    required this.liteAgentReady,
    required this.openToolDaemonReady,
    required this.reasons,
  });
}

class DaemonPresetToolCandidate {
  final String toolId;
  final String alias;
  final String status;
  final String serverUrl;
  final OpenTool spec;

  const DaemonPresetToolCandidate({
    required this.toolId,
    required this.alias,
    required this.status,
    required this.serverUrl,
    required this.spec,
  });
}

typedef DaemonPresetFilter = bool Function(DaemonPresetToolCandidate candidate);

class _PreferenceExtractorDelegate {
  final PreferenceExtractor preferenceExtractor;

  const _PreferenceExtractorDelegate({required this.preferenceExtractor});
}

class KernelService {
  final Kernel _kernel;
  static const String _defaultUserId = 'default';
  LlmConfigPool? _llmConfigPool;
  final SwitchablePreferenceExtractor? _preferenceExtractorSwitch;
  final LiteAgentClient? _liteAgentClient;
  final LlmQueue? _llmQueue;
  final OpenToolDaemonRegistry? _openToolDaemonRegistry;
  final KernelLogger? _logger;
  final DriftMemory? _driftMemory;
  PreferenceProcessor? _preferenceProcessor;
  bool _memorySummarizerStarted;
  MemorySummarizer? _memorySummarizer;
  final KernelRuntimeConfig _runtimeConfig;
  String _opentoolDaemonHost;
  int _opentoolDaemonPort;
  KernelMode _mode;
  final ModelProfiler? _modelProfiler;
  _OpenToolDaemonPresetSync? _openToolDaemonPresetSync;
  String? _openToolDaemonSyncApiKey;
  Duration _openToolDaemonSyncDebounce = const Duration(milliseconds: 200);
  DaemonPresetFilter? _openToolDaemonPresetFilter;
  final CronModule? _cronModule;
  final CronDaemonOpenSpecProvider? _cronDaemonAccess;
  final CronLlmConfigAccess? _cronLlmConfigAccess;
  final List<String>? _preferenceSkills;

  /// Wraps the kernel with a simplified API for external callers.
  factory KernelService(
    Kernel kernel, {
    LlmConfigPool? llmConfigPool,
    SwitchablePreferenceExtractor? preferenceExtractorSwitch,
    LiteAgentClient? liteAgentClient,
    LlmQueue? llmQueue,
    OpenToolDaemonRegistry? openToolDaemonRegistry,
    KernelLogger? logger,
    DriftMemory? driftMemory,
    bool memorySummarizerStarted = false,
    KernelRuntimeConfig runtimeConfig = const KernelRuntimeConfig(),
    String? opentoolDaemonHost,
    int? opentoolDaemonPort,
    ModelProfiler? modelProfiler,
    CronModule? cronModule,
    List<String>? preferenceSkills,
    PreferenceProcessor? preferenceProcessor,
  }) {
    return KernelService._internal(
      kernel,
      llmConfigPool: llmConfigPool,
      preferenceExtractorSwitch: preferenceExtractorSwitch,
      liteAgentClient: liteAgentClient,
      llmQueue: llmQueue,
      openToolDaemonRegistry: openToolDaemonRegistry,
      logger: logger,
      driftMemory: driftMemory,
      memorySummarizerStarted: memorySummarizerStarted,
      runtimeConfig: runtimeConfig,
      opentoolDaemonHost: opentoolDaemonHost,
      opentoolDaemonPort: opentoolDaemonPort,
      modelProfiler: modelProfiler,
      cronModule: cronModule,
      preferenceSkills: preferenceSkills,
      preferenceProcessor: preferenceProcessor,
    );
  }

  KernelService._internal(
    this._kernel, {
    LlmConfigPool? llmConfigPool,
    SwitchablePreferenceExtractor? preferenceExtractorSwitch,
    LiteAgentClient? liteAgentClient,
    LlmQueue? llmQueue,
    OpenToolDaemonRegistry? openToolDaemonRegistry,
    KernelLogger? logger,
    DriftMemory? driftMemory,
    bool memorySummarizerStarted = false,
    KernelRuntimeConfig runtimeConfig = const KernelRuntimeConfig(),
    String? opentoolDaemonHost,
    int? opentoolDaemonPort,
    ModelProfiler? modelProfiler,
    CronModule? cronModule,
    CronDaemonOpenSpecProvider? cronDaemonAccess,
    CronLlmConfigAccess? cronLlmConfigAccess,
    List<String>? preferenceSkills,
    PreferenceProcessor? preferenceProcessor,
  }) : _llmConfigPool = llmConfigPool,
       _preferenceExtractorSwitch = preferenceExtractorSwitch,
       _liteAgentClient = liteAgentClient,
       _llmQueue = llmQueue,
       _openToolDaemonRegistry = openToolDaemonRegistry,
       _logger = logger,
       _driftMemory = driftMemory,
       _memorySummarizerStarted = memorySummarizerStarted,
       _runtimeConfig = runtimeConfig,
       _opentoolDaemonHost =
           opentoolDaemonHost ?? runtimeConfig.opentoolDaemonHost,
       _opentoolDaemonPort =
           opentoolDaemonPort ?? runtimeConfig.opentoolDaemonPort,
       _mode = runtimeConfig.mode,
       _modelProfiler = modelProfiler,
       _cronModule = cronModule,
       _cronDaemonAccess = cronDaemonAccess,
       _cronLlmConfigAccess = cronLlmConfigAccess,
       _preferenceSkills = preferenceSkills,
       _preferenceProcessor = preferenceProcessor;

  String get defaultUserId => _defaultUserId;

  String getCurrentUserId() => _defaultUserId;

  KernelAdminService get admin => KernelAdminService(
    _kernel,
    triggerPreferenceExtraction: _triggerPreferenceExtractionInternal,
  );

  KernelMode getMode() => _mode;

  void setMode(KernelMode mode) {
    _mode = mode;
    _cronLlmConfigAccess?.mode = mode;
  }

  static Future<KernelService> create({
    KernelRuntimeConfig runtime = const KernelRuntimeConfig(),
  }) {
    return _createFromConfig(
      KernelServiceConfig(
        liteAgentSdk: LiteAgentSDK(baseUrl: 'http://127.0.0.1:65535'),
        runtime: runtime,
      ),
    );
  }

  static Future<KernelService> _createFromConfig(
    KernelServiceConfig config,
  ) async {
    final supervision = AdaptiveSupervision(
      ttftThreshold: config.runtime.ttftThreshold,
      tpsThreshold: config.runtime.tpsThreshold,
      maxConcurrency: config.runtime.maxConcurrency,
    );

    final logger = ConsoleKernelLogger();
    final llmQueue = LlmQueue(supervision: supervision, logger: logger);

    final liteAgentClient = LiteAgentClient(sdk: config.liteAgentSdk);
    final presetOpenSpecList = config.presetOpenSpecList;
    if (presetOpenSpecList != null) {
      await liteAgentClient.setPresetOpenSpecList(presetOpenSpecList);
    }
    supervision.startExternalServiceMonitoring(
      liteAgentSdk: config.liteAgentSdk,
      opentoolHost: config.runtime.opentoolDaemonHost,
      opentoolPort: config.runtime.opentoolDaemonPort,
    );

    LlmConfigPool? llmConfigPool;
    LLMConfig? llmConfig;
    final llmModels = config.llm?.models ?? const <KernelLlmModel>[];
    if (llmModels.isNotEmpty) {
      llmConfigPool = LlmConfigPool.fromModels(llmModels);
      supervision.updateModelCatalog(llmModels);
      llmConfig = llmConfigPool.pick();
      supervision.startLlmHealthMonitoring(llmModels);
    }

    final memoryDbPath = config.runtime.memoryDbPath;
    final resolvedMemoryDbPath =
        (memoryDbPath == null || memoryDbPath.trim().isEmpty)
        ? '.hive/kernel_memory.sqlite'
        : memoryDbPath.trim();
    final preferenceDbPath = config.runtime.preferenceDbPath;
    final resolvedPreferenceDbPath =
        (preferenceDbPath == null || preferenceDbPath.trim().isEmpty)
        ? '.hive/kernel_preference.sqlite'
        : preferenceDbPath.trim();
    final modelProfilerDbPath = config.runtime.modelProfilerDbPath;
    final resolvedModelProfilerDbPath =
        (modelProfilerDbPath == null || modelProfilerDbPath.trim().isEmpty)
        ? '.hive/kernel_model_profiles.sqlite'
        : modelProfilerDbPath.trim();
    final cronDbPath = config.runtime.cronDbPath;
    final resolvedCronDbPath = (cronDbPath == null || cronDbPath.trim().isEmpty)
        ? '.hive/kernel_cron.sqlite'
        : cronDbPath.trim();
    final modelProfiler = await ModelProfiler.open(
      path: resolvedModelProfilerDbPath,
    );
    supervision.setModelProfiler(modelProfiler);

    final openToolDaemonRegistry = OpenToolDaemonRegistry();

    final preference = DriftPreference.open(path: resolvedPreferenceDbPath);
    final longTermMemory = DriftMemory.open(path: resolvedMemoryDbPath);
    MemorySummarizer? memorySummarizer;
    final preferenceExtractorSwitch = SwitchablePreferenceExtractor(
      ThrowingPreferenceExtractor(),
    );
    if (llmConfig != null && llmConfigPool != null) {
      final preferenceExtractorDelegate = _buildPreferenceExtractor(
        llmQueue: llmQueue,
        client: liteAgentClient,
        llmConfig: llmConfig,
        pool: llmConfigPool,
        mode: () => config.runtime.mode,
        modelProfiler: modelProfiler,
        supervision: supervision,
        preference: preference,
        runtimeConfig: config.runtime,
        preferenceSkills: config.preferenceSkills,
      );
      preferenceExtractorSwitch.delegate =
          preferenceExtractorDelegate.preferenceExtractor;
    }
    final memoryPipeline = MemoryPipeline(memory: longTermMemory);
    final kernel = Kernel(
      openToolDaemonRegistry: openToolDaemonRegistry,
      supervision: supervision,
      memory: longTermMemory,
      memoryPipeline: memoryPipeline,
      preference: preference,
      preferenceExtractor: preferenceExtractorSwitch,
    );

    var memorySummarizerStarted = false;
    final cronDaemonAccess = CronDaemonOpenSpecProvider(
      host: config.runtime.opentoolDaemonHost,
      port: config.runtime.opentoolDaemonPort,
      logger: logger,
    );
    final cronLlmConfigAccess = CronLlmConfigAccess(
      pool: llmConfigPool,
      llmQueue: llmQueue,
      supervision: supervision,
      profiler: modelProfiler,
      mode: config.runtime.mode,
      profileSuccessRateThreshold: config.runtime.profileSuccessRateThreshold,
      purpose: 'cron',
    );
    final cronModule = CronModule(
      store: DriftCronTaskStore.open(path: resolvedCronDbPath),
      executor: AgentCronExecutor(
        sdkResolver: () => liteAgentClient.sdk,
        logger: logger,
        llmConfigResolver: cronLlmConfigAccess.resolve,
        llmConfigListResolver: cronLlmConfigAccess.resolveAll,
        daemonToolCatalogResolver: cronDaemonAccess.resolveCatalog,
        daemonHost: config.runtime.opentoolDaemonHost,
        daemonPort: config.runtime.opentoolDaemonPort,
      ),
    );
    PreferenceProcessor? preferenceProcessor;
    if (config.runtime.memorySummaryEnabled &&
        llmConfig != null &&
        llmConfigPool != null) {
      memorySummarizer = MemorySummarizer(
        memory: longTermMemory,
        llmQueue: llmQueue,
        client: liteAgentClient,
        llmConfig: llmConfig,
        llmConfigResolver: _makeResolver(
          pool: llmConfigPool,
          purpose: 'memory_summary',
          mode: () => config.runtime.mode,
          profiler: modelProfiler,
          supervision: supervision,
          runtimeConfig: config.runtime,
        ),
        logger: logger,
        interval: config.runtime.memorySummaryInterval,
        taskTimeout: config.runtime.memorySummaryTaskTimeout,
        recentWindow: config.runtime.memorySummaryRecentWindow,
        maxRecords: config.runtime.memorySummaryMaxRecords,
        minRecords: config.runtime.memorySummaryMinRecords,
        maxScopesPerRun: config.runtime.memorySummaryMaxScopesPerRun,
        enabled: true,
      );
      memorySummarizerStarted = true;
      memoryPipeline.summarizer = memorySummarizer;
    }
    if (llmConfig != null &&
        llmConfigPool != null &&
        config.runtime.preferenceExtractionEnabled) {
      preferenceProcessor = PreferenceProcessor(
        extractor: preferenceExtractorSwitch,
        llmQueue: llmQueue,
        logger: logger,
        interval: config.runtime.preferenceExtractionInterval,
        maxPerRun: config.runtime.preferenceExtractionMaxPerRun,
        queueLimit: config.runtime.preferenceExtractionQueueLimit,
        minRecords: config.runtime.preferenceExtractionMinRecords,
      );
    }
    final service = KernelService._internal(
      kernel,
      llmConfigPool: llmConfigPool,
      preferenceExtractorSwitch: preferenceExtractorSwitch,
      liteAgentClient: liteAgentClient,
      llmQueue: llmQueue,
      openToolDaemonRegistry: openToolDaemonRegistry,
      logger: logger,
      driftMemory: longTermMemory,
      memorySummarizerStarted: memorySummarizerStarted,
      runtimeConfig: config.runtime,
      opentoolDaemonHost: config.runtime.opentoolDaemonHost,
      opentoolDaemonPort: config.runtime.opentoolDaemonPort,
      modelProfiler: modelProfiler,
      cronModule: cronModule,
      cronDaemonAccess: cronDaemonAccess,
      cronLlmConfigAccess: cronLlmConfigAccess,
      preferenceSkills: config.preferenceSkills,
      preferenceProcessor: preferenceProcessor,
    );
    service._memorySummarizer = memorySummarizer;
    service._kernel.memoryPipeline.summarizer = memorySummarizer;
    await cronModule.start();
    return service;
  }

  // ConfirmationListener subscribeConfirmation({
  //   String? jobId,
  //   required void Function(String jobId) onNeedsConfirmation,
  // }) {
  //   // Planning-driven confirmation subscription is intentionally disabled.
  //   // return _jobSnapshotDispatcher.add(
  //   //   jobId: jobId,
  //   //   onNeedsConfirmation: (snapshot) {
  //   //     if (snapshot.status != JobStatus.NEEDS_CONFIRMATION) {
  //   //       return;
  //   //     }
  //   //     onNeedsConfirmation(snapshot.jobId);
  //   //   },
  //   // );
  //   throw StateError('Perception and planning flow is disabled.');
  // }

  LlmMetrics createLlmMetrics({
    required String requestId,
    required String baseUrl,
    required String model,
    String? apiKey,
    String? jobId,
    String? userId,
  }) {
    final sink = SupervisionLlmMetricsSink(
      supervision: _kernel.supervision,
      baseUrl: baseUrl,
      model: model,
      apiKey: apiKey ?? '',
      purpose: 'external_llm',
      priority: 0,
      weight: 1,
      jobId: jobId,
      userId: userId,
    );
    return LlmMetrics(requestId, sink);
  }

  Future<void> appendAgentMemoryMessage({
    required String sessionId,
    required String taskId,
    required String actorId,
    required AgentMemoryActorType actorType,
    required List<String> content,
    DateTime? timestamp,
  }) async {
    final driftMemory = _driftMemory;
    if (driftMemory == null) {
      throw StateError('DriftMemory is not managed by KernelService.');
    }
    await driftMemory.appendAgentMemoryMessage(
      sessionId: sessionId,
      taskId: taskId,
      actorId: actorId,
      actorType: actorType,
      content: content,
      timestamp: timestamp ?? DateTime.now(),
    );
    _kernel.memoryPipeline.markDirty();
    final actor = actorType.name;
    if (actor == AgentMemoryActorType.user.name ||
        actor == AgentMemoryActorType.app.name) {
      _preferenceProcessor?.enqueue(
        PreferenceSourceRecord(
          jobId: taskId,
          userId: _defaultUserId,
          type: 'agent_memory',
          data: {
            'sessionId': sessionId,
            'taskId': taskId,
            'actorId': actorId,
            'actorType': actorType.name,
            'content': content,
          },
          timestamp: timestamp ?? DateTime.now(),
        ),
      );
    }
  }

  Future<List<MemorySummary>> retrieveRelevantMemorySummaries(
    String instruction, {
    int limit = 6,
    int candidateLimit = 24,
  }) async {
    final keywords = _keywordTerms(instruction).toSet();
    if (keywords.isEmpty || limit <= 0 || candidateLimit <= 0) {
      return const [];
    }

    final summaries = await _kernel.memory.listMemorySummaries(limit: 0);
    final scored = <_ScoredMemorySummary>[];
    final now = DateTime.now();
    for (final summary in summaries) {
      final keywordHits = _countKeywordHits(keywords, summary.text);
      if (keywordHits == 0) {
        continue;
      }
      scored.add(
        _ScoredMemorySummary(
          summary: summary,
          keywordHits: keywordHits,
          timeScore:
              _memorySummaryRecencyScore(summary, now) * 0.2 +
              _memorySummaryTimeGroupBias(summary.bucket.name) * 0.1,
        ),
      );
    }

    scored.sort((a, b) {
      final byKeywords = b.keywordHits.compareTo(a.keywordHits);
      if (byKeywords != 0) return byKeywords;
      final byTimeScore = b.timeScore.compareTo(a.timeScore);
      if (byTimeScore != 0) return byTimeScore;
      return b.summary.updatedAt.compareTo(a.summary.updatedAt);
    });
    final seenTexts = <String>{};
    final candidates = scored
        .map((item) => item.summary)
        .where((summary) => seenTexts.add(summary.text.trim().toLowerCase()))
        .take(candidateLimit);
    final selected = <MemorySummary>[];
    final overflow = <MemorySummary>[];
    final quota = <String, int>{'near': 3, 'mid': 2, 'far': 1};

    for (final summary in candidates) {
      final family = _memorySummaryTimeFamily(summary.bucket.name);
      final remaining = quota[family]!;
      if (remaining == 0) {
        overflow.add(summary);
        continue;
      }
      quota[family] = remaining - 1;
      selected.add(summary);
      if (selected.length == limit) {
        break;
      }
    }
    selected.addAll(overflow.take(limit - selected.length));
    return selected;
  }

  Future<List<PreferenceEntry>> retrieveRelevantPreferences(
    String instruction, {
    String? userId,
    int limit = 3,
    int candidateLimit = 12,
  }) async {
    final keywords = _keywordTerms(instruction).toSet();
    final targetUserId = (userId ?? _defaultUserId).trim();
    if (keywords.isEmpty ||
        targetUserId.isEmpty ||
        limit <= 0 ||
        candidateLimit <= 0) {
      return const [];
    }

    final preferences = await _kernel.preference.listPreferences(
      userId: targetUserId,
      limit: 0,
    );
    final scored = <_ScoredPreferenceEntry>[];
    for (final entry in preferences) {
      final keywordHits = _countKeywordHits(keywords, entry.text);
      if (keywordHits > 0) {
        scored.add(
          _ScoredPreferenceEntry(entry: entry, keywordHits: keywordHits),
        );
      }
    }
    scored.sort((a, b) {
      final byKeywords = b.keywordHits.compareTo(a.keywordHits);
      if (byKeywords != 0) return byKeywords;
      final byRecency = b.entry.updatedAt.compareTo(a.entry.updatedAt);
      if (byRecency != 0) return byRecency;
      return a.entry.id.compareTo(b.entry.id);
    });
    return scored
        .take(candidateLimit)
        .take(limit)
        .map((item) => item.entry)
        .toList(growable: false);
  }

  Future<RelevantContext> retrieveRelevantContext(
    String instruction, {
    String? userId,
    int memoryLimit = 6,
    int memoryCandidateLimit = 24,
    int preferenceLimit = 3,
    int preferenceCandidateLimit = 12,
  }) async {
    final memorySummaries = await retrieveRelevantMemorySummaries(
      instruction,
      limit: memoryLimit,
      candidateLimit: memoryCandidateLimit,
    );
    final preferences = await retrieveRelevantPreferences(
      instruction,
      userId: userId,
      limit: preferenceLimit,
      candidateLimit: preferenceCandidateLimit,
    );
    return RelevantContext(
      memorySummaries: memorySummaries,
      preferences: preferences,
    );
  }

  Future<void> setPresetOpenSpecList(
    List<PresetOpenSpec> presetOpenSpecList,
  ) async {
    final liteAgentClient = _liteAgentClient;
    if (liteAgentClient == null) {
      throw StateError('LiteAgent client is not managed by KernelService.');
    }
    await liteAgentClient.setPresetOpenSpecList(presetOpenSpecList);
  }

  Future<void> updateLiteAgentSdk(
    LiteAgentSDK sdk, {
    List<PresetOpenSpec>? presetOpenSpecList,
  }) async {
    final liteAgentClient = _liteAgentClient;
    if (liteAgentClient == null) {
      throw StateError('LiteAgent client is not managed by KernelService.');
    }
    liteAgentClient.sdk = sdk;
    if (presetOpenSpecList != null) {
      await liteAgentClient.setPresetOpenSpecList(presetOpenSpecList);
    }
    _restartExternalServiceMonitoring();
    await _openToolDaemonPresetSync?.republish();
  }

  void updateOpenToolDaemon({required String host, required int port}) {
    final normalizedHost = host.trim();
    if (normalizedHost.isEmpty) {
      throw ArgumentError('host is required.');
    }
    if (port <= 0) {
      throw ArgumentError('port must be positive.');
    }
    _opentoolDaemonHost = normalizedHost;
    _opentoolDaemonPort = port;
    _cronDaemonAccess?.host = normalizedHost;
    _cronDaemonAccess?.port = port;
    _restartExternalServiceMonitoring();
    unawaited(_restartOpenToolDaemonPresetSync());
  }

  Future<void> startOpenToolDaemonPresetSync({
    required String daemonApiKey,
    Duration debounce = const Duration(milliseconds: 200),
    DaemonPresetFilter? presetFilter,
  }) async {
    final normalizedDaemonApiKey = daemonApiKey.trim();
    if (normalizedDaemonApiKey.isEmpty) {
      throw ArgumentError('daemonApiKey is required.');
    }
    final liteAgentClient = _liteAgentClient;
    if (liteAgentClient == null) {
      throw StateError('LiteAgent client is not managed by KernelService.');
    }
    _openToolDaemonSyncApiKey = normalizedDaemonApiKey;
    _openToolDaemonSyncDebounce = debounce;
    _openToolDaemonPresetFilter = presetFilter;
    final existing = _openToolDaemonPresetSync;
    if (existing != null) {
      await existing.dispose();
    }
    final sync = _OpenToolDaemonPresetSync(
      hostProvider: () => _opentoolDaemonHost,
      portProvider: () => _opentoolDaemonPort,
      daemonApiKey: _openToolDaemonSyncApiKey!,
      debounce: _openToolDaemonSyncDebounce,
      presetFilter: _openToolDaemonPresetFilter,
      // Temporarily keep daemon tools out of LiteAgent's global presets.
      // The daemon catalog remains available to the registry and to
      // session-scoped callbackOpenTool users such as cron execution.
      publishLiteAgentPresets: false,
      setPresetOpenSpecList: setPresetOpenSpecList,
      openToolDaemonRegistryProvider: _resolveOpenToolDaemonRegistry,
      logger: _logger,
    );
    _openToolDaemonPresetSync = sync;
    await sync.start();
  }

  Future<void> stopOpenToolDaemonPresetSync() async {
    _openToolDaemonSyncApiKey = null;
    _openToolDaemonPresetFilter = null;
    final existing = _openToolDaemonPresetSync;
    _openToolDaemonPresetSync = null;
    await existing?.dispose();
  }

  DaemonToolSyncSnapshot getOpenToolDaemonPresetSyncSnapshot() {
    final sync = _openToolDaemonPresetSync;
    if (sync == null) {
      return DaemonToolSyncSnapshot(
        running: false,
        host: _opentoolDaemonHost,
        port: _opentoolDaemonPort,
        revision: 0,
        activeTools: const [],
      );
    }
    return sync.snapshot();
  }

  void updateLlmModels(
    List<KernelLlmModel> models, {
    bool refreshServices = false,
  }) {
    if (models.isEmpty) {
      throw ArgumentError('models is required.');
    }
    var pool = _llmConfigPool;
    if (pool == null) {
      pool = LlmConfigPool.fromModels(models);
      _llmConfigPool = pool;
    } else {
      pool.updateFromModels(models);
    }
    _cronLlmConfigAccess?.pool = pool;
    final supervision = _kernel.supervision;
    if (supervision is AdaptiveSupervision) {
      supervision.updateModelCatalog(models);
      supervision.startLlmHealthMonitoring(models);
    }
    if (refreshServices) {
      updateLlmServices();
    }
  }

  void updateLlmServices() {
    final preferenceExtractorSwitch = _preferenceExtractorSwitch;
    final liteAgentClient = _liteAgentClient;
    final llmQueue = _llmQueue;
    final openToolDaemonRegistry = _openToolDaemonRegistry;
    if (preferenceExtractorSwitch == null ||
        liteAgentClient == null ||
        llmQueue == null ||
        openToolDaemonRegistry == null) {
      throw StateError('LLM config is not managed by KernelService.');
    }
    final pool = _llmConfigPool;
    if (pool == null || pool.configs.isEmpty) {
      throw StateError('LLM config is not managed by KernelService.');
    }
    final llmConfig = pool.pick();
    final supervision = _kernel.supervision;
    final profiler = _modelProfiler;
    final preferenceExtractorDelegate = _buildPreferenceExtractor(
      llmQueue: llmQueue,
      client: liteAgentClient,
      llmConfig: llmConfig,
      pool: pool,
      mode: () => _mode,
      modelProfiler: profiler,
      supervision: supervision,
      preference: _kernel.preference,
      runtimeConfig: _runtimeConfig,
      preferenceSkills: _preferenceSkills,
    );
    preferenceExtractorSwitch.delegate =
        preferenceExtractorDelegate.preferenceExtractor;
    if (_runtimeConfig.memorySummaryEnabled &&
        !_memorySummarizerStarted &&
        _driftMemory != null) {
      _memorySummarizer = MemorySummarizer(
        memory: _driftMemory,
        llmQueue: llmQueue,
        client: liteAgentClient,
        llmConfig: llmConfig,
        llmConfigResolver: _makeResolver(
          pool: pool,
          purpose: 'memory_summary',
          mode: () => _mode,
          profiler: profiler,
          supervision: supervision,
          runtimeConfig: _runtimeConfig,
        ),
        logger: _logger,
        interval: _runtimeConfig.memorySummaryInterval,
        taskTimeout: _runtimeConfig.memorySummaryTaskTimeout,
        recentWindow: _runtimeConfig.memorySummaryRecentWindow,
        maxRecords: _runtimeConfig.memorySummaryMaxRecords,
        minRecords: _runtimeConfig.memorySummaryMinRecords,
        maxScopesPerRun: _runtimeConfig.memorySummaryMaxScopesPerRun,
        enabled: true,
      );
      _memorySummarizerStarted = true;
      _kernel.memoryPipeline.summarizer = _memorySummarizer;
    }
    if (_runtimeConfig.preferenceExtractionEnabled) {
      _preferenceProcessor ??= PreferenceProcessor(
        extractor: preferenceExtractorSwitch,
        llmQueue: llmQueue,
        logger: _logger,
        interval: _runtimeConfig.preferenceExtractionInterval,
        maxPerRun: _runtimeConfig.preferenceExtractionMaxPerRun,
        queueLimit: _runtimeConfig.preferenceExtractionQueueLimit,
        minRecords: _runtimeConfig.preferenceExtractionMinRecords,
      );
    }
  }

  void _restartExternalServiceMonitoring() {
    final supervision = _kernel.supervision;
    final liteAgentClient = _liteAgentClient;
    if (supervision is! AdaptiveSupervision || liteAgentClient == null) {
      return;
    }
    supervision.startExternalServiceMonitoring(
      liteAgentSdk: liteAgentClient.sdk,
      opentoolHost: _opentoolDaemonHost,
      opentoolPort: _opentoolDaemonPort,
    );
  }

  Future<void> _restartOpenToolDaemonPresetSync() async {
    final daemonApiKey = _openToolDaemonSyncApiKey;
    if (daemonApiKey == null) {
      return;
    }
    await startOpenToolDaemonPresetSync(
      daemonApiKey: daemonApiKey,
      debounce: _openToolDaemonSyncDebounce,
      presetFilter: _openToolDaemonPresetFilter,
    );
  }

  Map<String, ModelHealthSnapshot> getModelHealth() {
    final supervision = _kernel.supervision;
    if (supervision is AdaptiveSupervision) {
      return supervision.modelHealthSnapshot();
    }
    return const {};
  }

  /// Pick the currently available LLM config for external callers.
  ///
  /// Availability is decided by supervision model health, current
  /// per-model concurrency/load, and the active [KernelMode].
  /// Returns null when no model can take new requests at the moment.
  LLMConfig? getAvailableLlmConfig({String purpose = 'external_llm'}) {
    final pool = _llmConfigPool;
    if (pool == null || pool.configs.isEmpty) {
      return null;
    }
    final supervision = _kernel.supervision;
    final modelCatalog = supervision is AdaptiveSupervision
        ? supervision.modelCatalog
        : const <String, KernelLlmModel>{};
    return pool.pickForPurpose(
      mode: _mode,
      purpose: purpose,
      isAvailable: (candidate) {
        if (!_isModelAvailable(supervision, candidate)) {
          return false;
        }
        final queue = _llmQueue;
        if (queue == null) return true;
        final key = buildLlmModelKey(
          baseUrl: candidate.baseUrl,
          model: candidate.model,
          apiKey: candidate.apiKey ?? '',
        );
        final snapshot = queue.snapshotForModel(key);
        final maxConcurrency = supervision.recommendedLlmConcurrency(
          snapshot,
          key,
        );
        return maxConcurrency > 0 && snapshot.inFlight < maxConcurrency;
      },
      profiler: _modelProfiler,
      modelCatalog: modelCatalog,
      successRateThreshold: _runtimeConfig.profileSuccessRateThreshold,
    );
  }

  ExternalServiceHealthSnapshot getExternalServiceHealth() {
    final supervision = _kernel.supervision;
    if (supervision is AdaptiveSupervision) {
      return supervision.externalServiceHealthSnapshot();
    }
    return const ExternalServiceHealthSnapshot(items: {});
  }

  KernelReadiness getReadiness({
    bool requireLlm = true,
    bool requireLiteAgent = true,
    bool requireOpenToolDaemon = false,
  }) {
    final reasons = <String>[];
    final llmConfigured = _llmConfigPool?.configs.isNotEmpty ?? false;
    final llmServicesReady = _areLlmServicesReady();
    final health = getExternalServiceHealth();
    final liteAgentReady = _hasHealthyExternalService(
      health,
      ExternalServiceType.liteagent,
    );
    final openToolDaemonReady = _hasHealthyExternalService(
      health,
      ExternalServiceType.opentoolDaemon,
    );
    if (requireLlm && !llmConfigured) {
      reasons.add('LLM models are not configured.');
    }
    if (requireLlm && !llmServicesReady) {
      reasons.add('LLM services are not activated. Call updateLlmServices().');
    }
    if (requireLiteAgent && !liteAgentReady) {
      reasons.add('LiteAgent service is not healthy yet.');
    }
    if (requireOpenToolDaemon && !openToolDaemonReady) {
      reasons.add('OpenTool daemon is not healthy yet.');
    }
    return KernelReadiness(
      ready: reasons.isEmpty,
      llmConfigured: llmConfigured,
      llmServicesReady: llmServicesReady,
      liteAgentReady: liteAgentReady,
      openToolDaemonReady: openToolDaemonReady,
      reasons: reasons,
    );
  }

  bool isReady({
    bool requireLlm = true,
    bool requireLiteAgent = true,
    bool requireOpenToolDaemon = false,
  }) {
    final readiness = getReadiness(
      requireLlm: requireLlm,
      requireLiteAgent: requireLiteAgent,
      requireOpenToolDaemon: requireOpenToolDaemon,
    );
    return readiness.ready;
  }

  ExternalServiceHealthSubscription onExternalServiceHealthChange(
    ExternalServiceHealthListener onChange,
  ) {
    final supervision = _kernel.supervision;
    if (supervision is AdaptiveSupervision) {
      return supervision.onExternalServiceHealthChange(onChange);
    }
    return ExternalServiceHealthSubscription(() {});
  }

  bool _areLlmServicesReady() {
    final preferenceExtractor = _preferenceExtractorSwitch;
    if (preferenceExtractor == null) {
      return false;
    }
    return preferenceExtractor.delegate is! ThrowingPreferenceExtractor;
  }

  bool _hasHealthyExternalService(
    ExternalServiceHealthSnapshot snapshot,
    ExternalServiceType type,
  ) {
    for (final item in snapshot.items.values) {
      if (item.type == type && item.available) {
        return true;
      }
    }
    return false;
  }

  Future<CronTaskDto> createCronTask({
    required String name,
    required String schedule,
    required AgentCronSpecDto spec,
    String source = KernelSources.api,
    String? sessionId,
    String? timezone,
    CronTaskConcurrencyDto concurrency = CronTaskConcurrencyDto.skipIfRunning,
    bool enabled = true,
  }) async {
    final module = _requireCronModule();
    final task = await module.createTask(
      name: name,
      schedule: schedule,
      spec: _toCronSpec(spec),
      source: source,
      sessionId: sessionId,
      timezone: timezone,
      concurrency: _toCronConcurrency(concurrency),
      enabled: enabled,
    );
    return _toCronTaskDto(task);
  }

  Future<CronTaskDto> updateCronTask({
    required String cronId,
    String? name,
    String? schedule,
    AgentCronSpecDto? spec,
    String? timezone,
    CronTaskConcurrencyDto? concurrency,
    bool? enabled,
  }) async {
    final module = _requireCronModule();
    final task = await module.updateTask(
      cronId: cronId,
      name: name,
      schedule: schedule,
      spec: spec == null ? null : _toCronSpec(spec),
      timezone: timezone,
      concurrency: concurrency == null ? null : _toCronConcurrency(concurrency),
      enabled: enabled,
    );
    return _toCronTaskDto(task);
  }

  Future<void> deleteCronTask(String cronId) {
    return _requireCronModule().deleteTask(cronId);
  }

  Future<CronTaskDto> getCronTask(String cronId) async {
    final task = await _requireCronModule().getTask(cronId);
    if (task == null) {
      throw StateError('Unknown cronId: $cronId');
    }
    return _toCronTaskDto(task);
  }

  Future<List<CronTaskListItemDto>> listCronTasks({
    bool? enabled,
    String? source,
    int offset = 0,
    int limit = 50,
  }) async {
    final tasks = await _requireCronModule().listTasks(
      enabled: enabled,
      source: source,
    );
    return tasks
        .skip(offset)
        .take(limit)
        .map(_toCronTaskListItemDto)
        .toList(growable: false);
  }

  Future<CronTaskDto> pauseCronTask(String cronId) async {
    return _toCronTaskDto(await _requireCronModule().pauseTask(cronId));
  }

  Future<CronTaskDto> resumeCronTask(String cronId) async {
    return _toCronTaskDto(await _requireCronModule().resumeTask(cronId));
  }

  Future<CronRunDto> runCronTaskNow(
    String cronId, {
    DateTime? scheduledAt,
  }) async {
    final run = await _requireCronModule().runTaskNow(
      cronId,
      scheduledAt: scheduledAt,
    );
    return _toCronRunDto(run);
  }

  Future<CronRunDto> getCronRun(String runId) async {
    final run = await _requireCronModule().getRun(runId);
    if (run == null) {
      throw StateError('Unknown cron runId: $runId');
    }
    return _toCronRunDto(run);
  }

  Future<void> deleteCronRun(String runId) {
    return _requireCronModule().deleteRun(runId);
  }

  Future<List<CronRunListItemDto>> listCronRuns({
    String? cronId,
    DateTime? after,
    DateTime? before,
    int offset = 0,
    int limit = 50,
    bool includeNonDisplayable = false,
  }) async {
    final runs = await _requireCronModule().listRuns(cronId: cronId);
    final filtered = runs.where((run) {
      if (!includeNonDisplayable && !run.hasDisplayableResult) {
        return false;
      }
      if (after != null && !run.startedAt.isAfter(after)) {
        return false;
      }
      if (before != null && run.startedAt.isAfter(before)) {
        return false;
      }
      return true;
    });
    return filtered
        .skip(offset)
        .take(limit)
        .map(_toCronRunListItemDto)
        .toList(growable: false);
  }

  Future<List<CronRunMessageDto>> listCronRunMessages(
    String runId, {
    int offset = 0,
    int limit = 200,
  }) async {
    final messages = await _requireCronModule().listRunMessages(runId);
    return messages
        .skip(offset)
        .take(limit)
        .map(_toCronRunMessageDto)
        .toList(growable: false);
  }

  Future<CronSchedulerSnapshotDto> getCronSchedulerSnapshot() async {
    final snapshot = await _requireCronModule().snapshot();
    return CronSchedulerSnapshotDto(
      running: snapshot.running,
      activeTaskCount: snapshot.activeTaskCount,
      runningTaskCount: snapshot.runningTaskCount,
      lastTickAt: snapshot.lastTickAt,
    );
  }

  void startCronScheduler() {
    unawaited(_requireCronModule().start());
  }

  Future<void> stopCronScheduler() {
    return _requireCronModule().stop();
  }

  // ---------------------------------------------------------------------------
  // Debug API
  // ---------------------------------------------------------------------------

  bool get debugMemorySummarizerAvailable =>
      _kernel.memoryPipeline.summarizerAvailable;

  Future<PreferenceExtractionTriggerResult>
  _triggerPreferenceExtractionInternal() async {
    final processor = _preferenceProcessor;
    if (processor == null) {
      return const PreferenceExtractionTriggerResult(
        preferences: [],
        sourceRecordCount: 0,
        minRequired: 1,
        reason: PreferenceExtractionTriggerResult.reasonEmpty,
      );
    }
    return processor.triggerNow();
  }

  // Debug/admin accessors live in KernelAdminService.

  static _PreferenceExtractorDelegate _buildPreferenceExtractor({
    required LlmQueue llmQueue,
    required LiteAgentClient client,
    required LLMConfig llmConfig,
    required LlmConfigPool pool,
    required KernelMode Function() mode,
    required ModelProfiler? modelProfiler,
    required Supervision supervision,
    required Preference preference,
    required KernelRuntimeConfig runtimeConfig,
    List<String>? preferenceSkills,
  }) {
    final preferenceExtractor = AgentPreferenceExtractor(
      llmQueue: llmQueue,
      client: client,
      preference: preference,
      llmConfig: llmConfig,
      llmConfigResolver: _makeResolver(
        pool: pool,
        purpose: 'preference_extraction',
        mode: mode,
        profiler: modelProfiler,
        supervision: supervision,
        runtimeConfig: runtimeConfig,
      ),
      systemPrompt:
          'You extract stable user preferences. Use generate_preference with a text array, or return an empty array.',
      taskTimeout: runtimeConfig.preferenceExtractionTaskTimeout,
      skills: preferenceSkills,
    );
    return _PreferenceExtractorDelegate(
      preferenceExtractor: preferenceExtractor,
    );
  }

  static LlmConfigResolver _makeResolver({
    LlmQueue? llmQueue,
    required LlmConfigPool pool,
    required String purpose,
    required KernelMode Function() mode,
    required ModelProfiler? profiler,
    required Supervision supervision,
    required KernelRuntimeConfig runtimeConfig,
  }) {
    return () {
      final modelCatalog = supervision is AdaptiveSupervision
          ? supervision.modelCatalog
          : const <String, KernelLlmModel>{};
      final activeMode = mode();
      final picked = pool.pickForPurpose(
        mode: activeMode,
        purpose: purpose,
        isAvailable: (candidate) =>
            _isModelAvailable(supervision, candidate) &&
            _hasQueueCapacity(
              supervision: supervision,
              llmQueue: llmQueue,
              candidate: candidate,
              requireCapacity: purpose == 'perception',
            ),
        profiler: profiler,
        modelCatalog: modelCatalog,
        successRateThreshold: runtimeConfig.profileSuccessRateThreshold,
      );
      if (picked != null) {
        return picked;
      }
      final relaxed = pool.pickForPurpose(
        mode: activeMode,
        purpose: purpose,
        isAvailable: (candidate) =>
            _isModelAvailable(supervision, candidate) &&
            _hasQueueCapacity(
              supervision: supervision,
              llmQueue: llmQueue,
              candidate: candidate,
              requireCapacity: purpose == 'perception',
            ),
        profiler: profiler,
        modelCatalog: modelCatalog,
        successRateThreshold: runtimeConfig.profileSuccessRateThreshold,
        allowProfilerSkip: false,
      );
      if (relaxed != null) {
        return relaxed;
      }
      return pool.pick(
        isAvailable: (candidate) =>
            _isModelAvailable(supervision, candidate) &&
            _hasQueueCapacity(
              supervision: supervision,
              llmQueue: llmQueue,
              candidate: candidate,
              requireCapacity: purpose == 'perception',
            ),
      );
    };
  }

  static bool _hasQueueCapacity({
    required Supervision supervision,
    required LlmQueue? llmQueue,
    required LLMConfig candidate,
    required bool requireCapacity,
  }) {
    if (!requireCapacity) {
      return true;
    }
    if (llmQueue == null) {
      return true;
    }
    final key = buildLlmModelKey(
      baseUrl: candidate.baseUrl,
      model: candidate.model,
      apiKey: candidate.apiKey ?? '',
    );
    final snapshot = llmQueue.snapshotForModel(key);
    final maxConcurrency = supervision.recommendedLlmConcurrency(snapshot, key);
    return maxConcurrency > 0 && snapshot.inFlight < maxConcurrency;
  }

  OpenToolDaemonRegistry _resolveOpenToolDaemonRegistry() {
    return _kernel.openToolDaemonRegistry;
  }

  CronModule _requireCronModule() {
    final module = _cronModule;
    if (module == null) {
      throw StateError('Cron module is not configured.');
    }
    return module;
  }

  AgentCronSpec _toCronSpec(AgentCronSpecDto dto) {
    return AgentCronSpec(
      systemPrompt: dto.systemPrompt,
      content: dto.content,
      timeoutSeconds: dto.timeoutSeconds,
      llmConfig: dto.llmConfig,
      skills: dto.skills,
    );
  }

  AgentCronSpecDto _toCronSpecDto(AgentCronSpec spec) {
    return AgentCronSpecDto(
      systemPrompt: spec.systemPrompt,
      content: spec.content,
      timeoutSeconds: spec.timeoutSeconds,
      llmConfig: spec.llmConfig,
      skills: spec.skills,
    );
  }

  CronTaskConcurrencyPolicy _toCronConcurrency(CronTaskConcurrencyDto value) {
    switch (value) {
      case CronTaskConcurrencyDto.allow:
        return CronTaskConcurrencyPolicy.allow;
      case CronTaskConcurrencyDto.replace:
        return CronTaskConcurrencyPolicy.replace;
      case CronTaskConcurrencyDto.skipIfRunning:
        return CronTaskConcurrencyPolicy.skipIfRunning;
    }
  }

  CronTaskConcurrencyDto _toCronConcurrencyDto(
    CronTaskConcurrencyPolicy value,
  ) {
    switch (value) {
      case CronTaskConcurrencyPolicy.allow:
        return CronTaskConcurrencyDto.allow;
      case CronTaskConcurrencyPolicy.replace:
        return CronTaskConcurrencyDto.replace;
      case CronTaskConcurrencyPolicy.skipIfRunning:
        return CronTaskConcurrencyDto.skipIfRunning;
    }
  }

  CronTaskDto _toCronTaskDto(CronTaskDefinition task) {
    return CronTaskDto(
      cronId: task.cronId,
      name: task.name,
      schedule: task.schedule,
      source: task.source,
      sessionId: task.sessionId,
      timezone: task.timezone,
      enabled: task.enabled,
      status: task.status.name,
      concurrency: _toCronConcurrencyDto(task.concurrency),
      createdAt: task.createdAt,
      updatedAt: task.updatedAt,
      lastRunAt: task.lastRunAt,
      nextRunAt: task.nextRunAt,
      spec: _toCronSpecDto(task.spec),
    );
  }

  CronTaskListItemDto _toCronTaskListItemDto(CronTaskDefinition task) {
    return CronTaskListItemDto(
      cronId: task.cronId,
      name: task.name,
      schedule: task.schedule,
      enabled: task.enabled,
      status: task.status.name,
      lastRunAt: task.lastRunAt,
      nextRunAt: task.nextRunAt,
    );
  }

  CronRunDto _toCronRunDto(CronRunRecord run) {
    return CronRunDto(
      runId: run.runId,
      cronId: run.cronId,
      trigger: run.trigger.name,
      status: run.status.name,
      scheduledAt: run.scheduledAt,
      startedAt: run.startedAt,
      hasDisplayableResult: run.hasDisplayableResult,
      finishedAt: run.finishedAt,
      llmConfig: run.llmConfig,
      liteAgentSessionId: run.liteAgentSessionId,
      error: run.error,
      result: run.result,
      displayMessageId: run.displayMessageId,
      displayText: run.displayText,
    );
  }

  CronRunListItemDto _toCronRunListItemDto(CronRunRecord run) {
    return CronRunListItemDto(
      runId: run.runId,
      cronId: run.cronId,
      trigger: run.trigger.name,
      status: run.status.name,
      scheduledAt: run.scheduledAt,
      startedAt: run.startedAt,
      hasDisplayableResult: run.hasDisplayableResult,
      finishedAt: run.finishedAt,
      llmConfig: run.llmConfig,
      displayText: run.displayText,
    );
  }

  CronRunMessageDto _toCronRunMessageDto(CronRunMessageRecord message) {
    return CronRunMessageDto(
      messageId: message.messageId,
      runId: message.runId,
      cronId: message.cronId,
      timestamp: message.timestamp,
      message: message.message,
    );
  }
}

double _memorySummaryRecencyScore(MemorySummary summary, DateTime now) {
  final age = now.difference(summary.updatedAt);
  if (age.inHours <= 6) {
    return 1.0;
  }
  if (age.inDays <= 1) {
    return 0.9;
  }
  if (age.inDays <= 7) {
    return 0.75;
  }
  if (age.inDays <= 30) {
    return 0.6;
  }
  if (age.inDays <= 90) {
    return 0.45;
  }
  return 0.3;
}

double _memorySummaryTimeGroupBias(String timeGroup) {
  switch (timeGroup) {
    case 'recent':
      return 1.0;
    case 'day':
      return 0.9;
    case 'week':
      return 0.75;
    case 'month':
      return 0.6;
    case 'quarter':
      return 0.45;
    case 'archive':
      return 0.3;
    default:
      return 0.5;
  }
}

String _memorySummaryTimeFamily(String timeGroup) {
  switch (timeGroup) {
    case 'recent':
    case 'day':
      return 'near';
    case 'week':
    case 'month':
      return 'mid';
    case 'quarter':
    case 'archive':
      return 'far';
    default:
      return 'mid';
  }
}

bool _isModelAvailable(Supervision supervision, LLMConfig config) {
  if (supervision is AdaptiveSupervision) {
    final snapshot = supervision.modelHealthSnapshot();
    final modelKey = buildLlmModelKey(
      baseUrl: config.baseUrl,
      model: config.model,
      apiKey: config.apiKey,
    );
    final health = snapshot[modelKey];
    return health?.available ?? true;
  }
  return true;
}

class _OpenToolDaemonPresetSync {
  final String Function() hostProvider;
  final int Function() portProvider;
  final String daemonApiKey;
  final Duration debounce;
  final DaemonPresetFilter? presetFilter;
  final bool publishLiteAgentPresets;
  final Future<void> Function(List<PresetOpenSpec>) setPresetOpenSpecList;
  final OpenToolDaemonRegistry Function() openToolDaemonRegistryProvider;
  final KernelLogger? logger;

  StreamSubscription<ToolLifecycleEventDto>? _subscription;
  Timer? _publishTimer;
  bool _disposed = false;
  int _revision = 0;
  final Map<String, int> _toolEpochById = {};
  final Map<String, _DaemonActiveTool> _activeTools = {};
  final Set<String> _directoryToolIds = {};

  _OpenToolDaemonPresetSync({
    required this.hostProvider,
    required this.portProvider,
    required this.daemonApiKey,
    required this.debounce,
    required this.presetFilter,
    required this.publishLiteAgentPresets,
    required this.setPresetOpenSpecList,
    required this.openToolDaemonRegistryProvider,
    this.logger,
  });

  Future<void> start() async {
    await _subscription?.cancel();
    final client = _client();
    final stream = await client.subscribeToolEvents(
      daemonApiKey: daemonApiKey,
      snapshot: true,
    );
    _subscription = stream.listen(
      (event) {
        unawaited(_handleEvent(event));
      },
      onError: (Object error, StackTrace stackTrace) {
        logger?.error(
          'OpenTool daemon preset sync stream failed.',
          error,
          data: {'stackTrace': stackTrace.toString()},
        );
      },
    );
  }

  DaemonToolSyncSnapshot snapshot() {
    final items = <DaemonToolSyncItem>[
      for (final tool in _activeTools.values)
        DaemonToolSyncItem(
          toolId: tool.toolId,
          alias: tool.alias,
          status: tool.status,
          endpoint: tool.serverUrl,
          updatedAt: tool.updatedAt,
        ),
    ]..sort((a, b) => a.toolId.compareTo(b.toolId));
    return DaemonToolSyncSnapshot(
      running: !_disposed && _subscription != null,
      host: hostProvider(),
      port: portProvider(),
      revision: _revision,
      activeTools: items,
    );
  }

  Future<void> republish() async {
    _schedulePublish(immediate: true);
    await _flushPendingPublish();
  }

  Future<void> dispose() async {
    _disposed = true;
    _publishTimer?.cancel();
    _publishTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    _clearDirectoryTools();
    if (publishLiteAgentPresets) {
      try {
        await setPresetOpenSpecList(const []);
      } catch (_) {
        // Ignore cleanup failures while shutting down the sync bridge.
      }
    }
  }

  Future<void> _handleEvent(ToolLifecycleEventDto event) async {
    if (_disposed) {
      return;
    }
    final toolId = event.tool.id;
    final nextEpoch = (_toolEpochById[toolId] ?? 0) + 1;
    _toolEpochById[toolId] = nextEpoch;

    switch (event.type) {
      case _DaemonToolLifecycleEventType.ready:
        await _activateTool(toolId, nextEpoch);
        return;
      case _DaemonToolLifecycleEventType.snapshot:
        if (event.tool.status == _DaemonToolStatusType.running) {
          await _activateTool(toolId, nextEpoch);
        } else {
          _deactivateTool(toolId);
        }
        return;
      case _DaemonToolLifecycleEventType.draining:
      case _DaemonToolLifecycleEventType.unavailable:
      case _DaemonToolLifecycleEventType.removed:
        _deactivateTool(toolId);
        return;
    }
  }

  Future<void> _activateTool(String toolId, int epoch) async {
    final client = _client();
    try {
      final toolList = await client.listToolWithApiKeys(
        '1',
        daemonApiKey: daemonApiKey,
      );
      ToolWithApiKeyDto? toolInfo;
      for (final candidate in toolList) {
        if (candidate.id == toolId) {
          toolInfo = candidate;
          break;
        }
      }
      if (toolInfo == null ||
          toolInfo.status != _DaemonToolStatusType.running) {
        _deactivateTool(toolId);
        return;
      }
      final spec = await client.loadTool(toolId);
      if (spec == null) {
        _deactivateTool(toolId);
        return;
      }
      if (_disposed || _toolEpochById[toolId] != epoch) {
        return;
      }
      _activeTools[toolId] = _DaemonActiveTool.fromLoaded(
        toolInfo: toolInfo,
        spec: spec,
      );
      _schedulePublish();
    } catch (error, stackTrace) {
      logger?.warn(
        'OpenTool daemon preset sync failed to activate tool.',
        data: {
          'toolId': toolId,
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
      if (_toolEpochById[toolId] == epoch) {
        _deactivateTool(toolId);
      }
    }
  }

  void _deactivateTool(String toolId) {
    final removed = _activeTools.remove(toolId);
    if (removed != null ||
        _directoryToolIds.contains(_directoryToolId(toolId))) {
      _schedulePublish(immediate: true);
    }
  }

  void _schedulePublish({bool immediate = false}) {
    if (_disposed) {
      return;
    }
    _publishTimer?.cancel();
    final delay = immediate ? Duration.zero : debounce;
    _publishTimer = Timer(delay, () {
      unawaited(_publish());
    });
  }

  Future<void> _flushPendingPublish() async {
    final timer = _publishTimer;
    if (timer == null) {
      return;
    }
    if (timer.isActive) {
      final completer = Completer<void>();
      _publishTimer = Timer(Duration.zero, () async {
        await _publish();
        completer.complete();
      });
      await completer.future;
    }
  }

  Future<void> _publish() async {
    if (_disposed) {
      return;
    }
    _publishTimer?.cancel();
    _publishTimer = null;
    _revision += 1;
    final activeTools = _activeTools.values.toList()
      ..sort((a, b) => a.toolId.compareTo(b.toolId));
    final registry = openToolDaemonRegistryProvider();
    final nextDirectoryToolIds = <String>{};
    for (final tool in activeTools) {
      final directoryToolId = _directoryToolId(tool.toolId);
      nextDirectoryToolIds.add(directoryToolId);
      registry.registerRemote(
        tool.spec,
        toolId: directoryToolId,
        serverUrl: tool.serverUrl,
        apiKey: tool.apiKey,
      );
    }
    for (final toolId in _directoryToolIds.difference(nextDirectoryToolIds)) {
      registry.unregister(toolId);
    }
    _directoryToolIds
      ..clear()
      ..addAll(nextDirectoryToolIds);
    // Temporarily disabled: publishing every daemon tool as a global LiteAgent
    // preset makes every LiteAgent session carry an unnecessarily large tool
    // surface. Keep the original publishing path behind a switch so it can be
    // restored after task-scoped tool selection is available.
    if (publishLiteAgentPresets) {
      final presetList = activeTools
          .where((tool) => presetFilter?.call(tool.toPresetCandidate()) ?? true)
          .map((tool) => tool.preset)
          .toList();
      await setPresetOpenSpecList(presetList);
    }
  }

  void _clearDirectoryTools() {
    final registry = openToolDaemonRegistryProvider();
    for (final toolId in _directoryToolIds) {
      registry.unregister(toolId);
    }
    _directoryToolIds.clear();
  }

  DaemonClient _client() =>
      DaemonClient(host: hostProvider(), port: portProvider());

  String _directoryToolId(String toolId) => 'daemon:$toolId';
}

final _keywordPattern = RegExp(
  r'(\p{Script=Han}+)|(?:(?!\p{Script=Han})[\p{L}\p{M}\p{N}])+',
  unicode: true,
);

Iterable<String> _keywordTerms(
  String text, {
  bool includeHanCharacters = false,
}) sync* {
  for (final match in _keywordPattern.allMatches(text.toLowerCase())) {
    final han = match.group(1);
    if (han == null) {
      yield match.group(0)!;
      continue;
    }
    // Han text often has no word separators. Match adjacent character pairs
    // and allow an isolated query character to match within a longer run.
    final characters = han.runes.toList(growable: false);
    for (var i = 0; i < characters.length; i += 1) {
      if (includeHanCharacters || characters.length == 1) {
        yield String.fromCharCode(characters[i]);
      }
      if (i + 1 < characters.length) {
        yield String.fromCharCodes(characters, i, i + 2);
      }
    }
  }
}

int _countKeywordHits(Set<String> keywords, String text) {
  final matched = _keywordTerms(
    text,
    includeHanCharacters: true,
  ).where(keywords.contains).toSet();
  return matched.length;
}

class _ScoredMemorySummary {
  final MemorySummary summary;
  final int keywordHits;
  final double timeScore;

  const _ScoredMemorySummary({
    required this.summary,
    required this.keywordHits,
    required this.timeScore,
  });
}

class _ScoredPreferenceEntry {
  final PreferenceEntry entry;
  final int keywordHits;

  const _ScoredPreferenceEntry({
    required this.entry,
    required this.keywordHits,
  });
}

class _DaemonActiveTool {
  final String toolId;
  final String alias;
  final String status;
  final String apiKey;
  final String serverUrl;
  final OpenTool spec;
  final PresetOpenSpec preset;
  final DateTime updatedAt;

  const _DaemonActiveTool({
    required this.toolId,
    required this.alias,
    required this.status,
    required this.apiKey,
    required this.serverUrl,
    required this.spec,
    required this.preset,
    required this.updatedAt,
  });

  factory _DaemonActiveTool.fromLoaded({
    required ToolWithApiKeyDto toolInfo,
    required OpenTool spec,
  }) {
    final serverUrl = 'http://${toolInfo.host}:${toolInfo.port}';
    final specJson = jsonEncode(spec.toJson());
    return _DaemonActiveTool(
      toolId: toolInfo.id,
      alias: toolInfo.alias,
      status: toolInfo.status,
      apiKey: toolInfo.apiKey,
      serverUrl: serverUrl,
      spec: spec,
      preset: PresetOpenSpec(
        systemPrompt: _buildSystemPrompt(spec),
        openSpec: OpenSpec(
          openSpec: specJson,
          protocol: Protocol.opentool,
          serverUrl: serverUrl,
          apiKey: ApiKey(type: ApiKeyType.original, apiKey: toolInfo.apiKey),
        ),
      ),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  DaemonPresetToolCandidate toPresetCandidate() {
    return DaemonPresetToolCandidate(
      toolId: toolId,
      alias: alias,
      status: status,
      serverUrl: serverUrl,
      spec: spec,
    );
  }

  static String _buildSystemPrompt(OpenTool spec) {
    final title = spec.info.title.trim();
    final description = (spec.info.description ?? '').trim();
    if (title.isEmpty && description.isEmpty) {
      return 'Use this tool when its functions match the user request.';
    }
    if (description.isEmpty) {
      return 'Use the "$title" tool when its functions match the user request.';
    }
    if (title.isEmpty) {
      return 'Use this tool when needed: $description';
    }
    return 'Use the "$title" tool when needed: $description';
  }
}

class _DaemonToolLifecycleEventType {
  static const String ready = 'tool.ready';
  static const String draining = 'tool.draining';
  static const String unavailable = 'tool.unavailable';
  static const String removed = 'tool.removed';
  static const String snapshot = 'tool.snapshot';
}

class _DaemonToolStatusType {
  static const String running = 'running';
}
