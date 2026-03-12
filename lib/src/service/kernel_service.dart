import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hive/hive.dart';
import 'package:lite_embeddings_sdk_dart/lite_embeddings_sdk_dart.dart'
    as embeddings;
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_daemon/opentool_daemon_client.dart';
import 'package:opentool_dart/opentool_client.dart';

import '../kernel/execution/execution.dart';
import '../kernel/execution/open_tool_directory.dart';
import '../kernel/execution/app_called_tool.dart';
import '../kernel/job_manager.dart';
import '../kernel/job_manager_hive.dart';
import '../kernel/kernel.dart';
import '../kernel/learning/deferred_learning.dart';
import '../kernel/learning/liteagent_learning.dart';
import '../kernel/learning/learning.dart';
import '../kernel/agent/liteagent_client.dart';
import '../kernel/agent/llm_metrics.dart';
import '../kernel/agent/llm_queue.dart';
import '../kernel/agent/config.dart';
import '../kernel/agent/model.dart';
import '../kernel/logging/logger.dart';
import '../kernel/memory/drift_memory.dart';
import '../kernel/memory/memory_summarizer.dart';
import '../kernel/memory/model.dart';
import '../kernel/perception/model.dart';
import '../kernel/preference/model.dart';
import '../kernel/perception/contextual_perception.dart';
import '../kernel/perception/input.dart';
import '../kernel/perception/liteagent_perception.dart';
import '../kernel/perception/perception.dart';
import '../kernel/perception/perception_agent_runner.dart';
import '../kernel/planning/planning.dart';
import '../kernel/preference/hive_preference.dart';
import '../kernel/preference/preference.dart';
import '../kernel/preference/lite_embeddings_vector_store.dart';
import '../kernel/preference/vector_store.dart';
import '../kernel/supervision/model.dart';
import '../kernel/supervision/model_profiler.dart';
import '../kernel/supervision/supervision.dart';
import 'dto.dart';
import 'model.dart';

class LlmConfigGroup {
  final List<KernelLlmModel> models;

  const LlmConfigGroup({required this.models});
}

class EmbeddingsConfig {
  final String baseUrl;
  final String? apiKey;
  final String docsName;
  final String? model;
  final String? llmModel;

  const EmbeddingsConfig({
    required this.baseUrl,
    this.apiKey,
    required this.docsName,
    this.model,
    this.llmModel,
  });
}

class KernelRuntimeConfig {
  final String hivePath;
  final String? memoryDbPath;
  final String jobBoxName;
  final String preferenceBoxName;
  final Duration ttftThreshold;
  final double tpsThreshold;
  final int maxConcurrency;
  final double maxPreferenceDistance;
  final int vectorQueryLimit;
  final int maxPreferenceResults;
  final int memorySummaryLimit;
  final Duration memorySummaryRecentWindow;
  final int memorySummaryMaxRecords;
  final int memorySummaryMinRecords;
  final bool memorySummaryEnabled;
  final Duration memorySummaryInterval;
  final int memorySummaryMaxScopesPerRun;
  final bool learningDeferredEnabled;
  final Duration learningInterval;
  final int learningMaxPerRun;
  final int learningQueueLimit;
  final String opentoolDaemonHost;
  final int opentoolDaemonPort;
  final KernelMode mode;
  final String modelProfileBoxName;
  final double profileSuccessRateThreshold;

  const KernelRuntimeConfig({
    this.hivePath = '.hive',
    this.memoryDbPath = '.hive/kernel_memory.sqlite',
    this.jobBoxName = 'kernel_jobs',
    this.preferenceBoxName = 'kernel_preference',
    this.ttftThreshold = const Duration(milliseconds: 5000),
    this.tpsThreshold = 5.0,
    this.maxConcurrency = 8,
    this.maxPreferenceDistance = 0.35,
    this.vectorQueryLimit = 5,
    this.maxPreferenceResults = 3,
    this.memorySummaryLimit = 5,
    this.memorySummaryRecentWindow = const Duration(hours: 24),
    this.memorySummaryMaxRecords = 200,
    this.memorySummaryMinRecords = 20,
    this.memorySummaryEnabled = true,
    this.memorySummaryInterval = const Duration(minutes: 5),
    this.memorySummaryMaxScopesPerRun = 1,
    this.learningDeferredEnabled = true,
    this.learningInterval = const Duration(minutes: 5),
    this.learningMaxPerRun = 1,
    this.learningQueueLimit = 500,
    this.opentoolDaemonHost = '127.0.0.1',
    this.opentoolDaemonPort = DAEMON_DEFAULT_PORT,
    this.mode = KernelMode.balanced,
    this.modelProfileBoxName = 'kernel_model_profiles',
    this.profileSuccessRateThreshold = 0.4,
  });
}

class KernelServiceConfig {
  final LiteAgentSDK liteAgentSdk;
  final List<PresetOpenSpec>? presetOpenSpecList;
  final LlmConfigGroup? llm;
  final EmbeddingsConfig embeddings;
  final KernelRuntimeConfig runtime;

  const KernelServiceConfig({
    required this.liteAgentSdk,
    this.presetOpenSpecList,
    this.llm,
    required this.embeddings,
    this.runtime = const KernelRuntimeConfig(),
  });
}

class KernelReadiness {
  final bool ready;
  final bool llmConfigured;
  final bool llmServicesReady;
  final bool liteAgentReady;
  final bool openToolDaemonReady;
  final bool embeddingsReady;
  final List<String> reasons;

  const KernelReadiness({
    required this.ready,
    required this.llmConfigured,
    required this.llmServicesReady,
    required this.liteAgentReady,
    required this.openToolDaemonReady,
    required this.embeddingsReady,
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

class _LlmServiceDelegates {
  final Perception perception;
  final Planning planning;
  final Learning learning;

  const _LlmServiceDelegates({
    required this.perception,
    required this.planning,
    required this.learning,
  });
}

class KernelService {
  final Kernel _kernel;
  final PerceptionAgentRunner? _perceptionRunner;
  static const String _defaultUserId = 'default';
  LlmConfigPool? _llmConfigPool;
  final SwitchablePerception? _perceptionSwitch;
  final SwitchablePlanning? _planningSwitch;
  final SwitchableLearning? _learningSwitch;
  final LiteAgentClient? _liteAgentClient;
  final LlmQueue? _llmQueue;
  final OpenToolDirectory? _openToolDirectory;
  final KernelLogger? _logger;
  final DriftMemory? _driftMemory;
  final SwitchableTextQueryVectorStore? _preferenceVectorStore;
  bool _memorySummarizerStarted;
  final _JobSnapshotDispatcher _jobSnapshotDispatcher;
  AppCalledTool? _appCalledTool;
  final KernelRuntimeConfig _runtimeConfig;
  String _opentoolDaemonHost;
  int _opentoolDaemonPort;
  String _embeddingsBaseUrl;
  KernelMode _mode;
  final ModelProfiler? _modelProfiler;
  _OpenToolDaemonPresetSync? _openToolDaemonPresetSync;
  String? _openToolDaemonSyncApiKey;
  Duration _openToolDaemonSyncDebounce = const Duration(milliseconds: 200);
  DaemonPresetFilter? _openToolDaemonPresetFilter;

  /// Wraps the kernel with a simplified API for external callers.
  factory KernelService(
    Kernel kernel, {
    PerceptionAgentRunner? perceptionRunner,
    LlmConfigPool? llmConfigPool,
    SwitchablePerception? perceptionSwitch,
    SwitchablePlanning? planningSwitch,
    SwitchableLearning? learningSwitch,
    LiteAgentClient? liteAgentClient,
    LlmQueue? llmQueue,
    OpenToolDirectory? openToolDirectory,
    KernelLogger? logger,
    DriftMemory? driftMemory,
    SwitchableTextQueryVectorStore? preferenceVectorStore,
    bool memorySummarizerStarted = false,
    KernelRuntimeConfig runtimeConfig = const KernelRuntimeConfig(),
    String? opentoolDaemonHost,
    int? opentoolDaemonPort,
    String embeddingsBaseUrl = '',
    ModelProfiler? modelProfiler,
  }) {
    return KernelService._internal(
      kernel,
      perceptionRunner: perceptionRunner,
      llmConfigPool: llmConfigPool,
      perceptionSwitch: perceptionSwitch,
      planningSwitch: planningSwitch,
      learningSwitch: learningSwitch,
      liteAgentClient: liteAgentClient,
      llmQueue: llmQueue,
      openToolDirectory: openToolDirectory,
      logger: logger,
      driftMemory: driftMemory,
      preferenceVectorStore: preferenceVectorStore,
      memorySummarizerStarted: memorySummarizerStarted,
      runtimeConfig: runtimeConfig,
      opentoolDaemonHost: opentoolDaemonHost,
      opentoolDaemonPort: opentoolDaemonPort,
      embeddingsBaseUrl: embeddingsBaseUrl,
      modelProfiler: modelProfiler,
    );
  }

  KernelService._internal(
    this._kernel, {
    PerceptionAgentRunner? perceptionRunner,
    LlmConfigPool? llmConfigPool,
    SwitchablePerception? perceptionSwitch,
    SwitchablePlanning? planningSwitch,
    SwitchableLearning? learningSwitch,
    LiteAgentClient? liteAgentClient,
    LlmQueue? llmQueue,
    OpenToolDirectory? openToolDirectory,
    KernelLogger? logger,
    DriftMemory? driftMemory,
    SwitchableTextQueryVectorStore? preferenceVectorStore,
    bool memorySummarizerStarted = false,
    _JobSnapshotDispatcher? jobSnapshotDispatcher,
    KernelRuntimeConfig runtimeConfig = const KernelRuntimeConfig(),
    String? opentoolDaemonHost,
    int? opentoolDaemonPort,
    String embeddingsBaseUrl = '',
    ModelProfiler? modelProfiler,
  }) : _perceptionRunner = perceptionRunner,
       _llmConfigPool = llmConfigPool,
       _perceptionSwitch = perceptionSwitch,
       _planningSwitch = planningSwitch,
       _learningSwitch = learningSwitch,
       _liteAgentClient = liteAgentClient,
       _llmQueue = llmQueue,
       _openToolDirectory = openToolDirectory,
       _logger = logger,
       _driftMemory = driftMemory,
       _preferenceVectorStore = preferenceVectorStore,
       _memorySummarizerStarted = memorySummarizerStarted,
       _jobSnapshotDispatcher =
           jobSnapshotDispatcher ?? _JobSnapshotDispatcher(),
       _runtimeConfig = runtimeConfig,
       _opentoolDaemonHost =
           opentoolDaemonHost ?? runtimeConfig.opentoolDaemonHost,
       _opentoolDaemonPort =
           opentoolDaemonPort ?? runtimeConfig.opentoolDaemonPort,
       _embeddingsBaseUrl = embeddingsBaseUrl,
       _mode = runtimeConfig.mode,
       _modelProfiler = modelProfiler;

  String get defaultUserId => _defaultUserId;

  String getCurrentUserId() => _defaultUserId;

  KernelMode getMode() => _mode;

  void setMode(KernelMode mode) {
    _mode = mode;
  }

  static Future<KernelService> create({
    KernelRuntimeConfig runtime = const KernelRuntimeConfig(),
  }) {
    return _createFromConfig(
      KernelServiceConfig(
        liteAgentSdk: LiteAgentSDK(baseUrl: 'http://127.0.0.1:65535'),
        embeddings: const EmbeddingsConfig(
          baseUrl: 'http://127.0.0.1:65534',
          docsName: 'bootstrap',
        ),
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
      embeddingsBaseUrl: config.embeddings.baseUrl,
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

    final embeddingsClient = embeddings.LiteEmbeddingsClient(
      baseUrl: config.embeddings.baseUrl,
      bearerToken: config.embeddings.apiKey,
    );
    TextQueryVectorStore embeddingsVectorStore;
    if (llmModels.isNotEmpty) {
      try {
        final embeddingsModel = _resolveEmbeddingsLlmModel(
          llmModels,
          config.embeddings.llmModel,
        );
        final embeddingsLlmConfig = embeddings.LLMConfig(
          baseUrl: embeddingsModel.baseUrl,
          apiKey: embeddingsModel.apiKey ?? '',
          model: _resolveEmbeddingsModel(
            config.embeddings.model,
            embeddingsModel.model,
          ),
        );
        final embeddingsDocsId = await _ensureDocsId(
          embeddingsClient,
          config.embeddings.docsName,
          embeddingsLlmConfig,
        );
        embeddingsVectorStore = LiteEmbeddingsVectorStore(
          client: embeddingsClient,
          docsId: embeddingsDocsId,
          llmConfig: embeddingsLlmConfig,
        );
      } catch (_) {
        embeddingsVectorStore = ThrowingTextQueryVectorStore();
      }
    } else {
      embeddingsVectorStore = ThrowingTextQueryVectorStore();
    }

    Hive.init(Directory(config.runtime.hivePath).path);
    final memoryDbPath = config.runtime.memoryDbPath;
    final resolvedMemoryDbPath =
        (memoryDbPath == null || memoryDbPath.trim().isEmpty)
        ? '.hive/kernel_memory.sqlite'
        : memoryDbPath.trim();
    final jobBox = await Hive.openBox<Map>(config.runtime.jobBoxName);
    final preferenceBox = await Hive.openBox<Map>(
      config.runtime.preferenceBoxName,
    );
    final modelProfileBox = await Hive.openBox<Map>(
      config.runtime.modelProfileBoxName,
    );
    final modelProfiler = ModelProfiler(box: modelProfileBox);
    supervision.setModelProfiler(modelProfiler);

    final openToolDirectory = OpenToolDirectory();

    final vectorStore = SwitchableTextQueryVectorStore(embeddingsVectorStore);
    final preference = HivePreference(
      box: preferenceBox,
      vectorStore: vectorStore,
    );

    final perceptionDelegateSwitch = SwitchablePerception(ThrowingPerception());
    final perception = ContextualPerception(
      delegate: perceptionDelegateSwitch,
      enrich: (input) async {
        final text = input.text?.trim();
        final targetUserId = input.userId;
        if (text == null || text.isEmpty) {
          return null;
        }
        if (targetUserId == null || targetUserId.trim().isEmpty) {
          return null;
        }
        try {
          final matches = await vectorStore.queryByText(
            text,
            limit: config.runtime.vectorQueryLimit,
          );
          final filtered = matches
              .where(
                (match) =>
                    match.payload?['userId'] == targetUserId &&
                    _isRelevantMatch(
                      match,
                      config.runtime.maxPreferenceDistance,
                    ),
              )
              .toList();
          if (filtered.isEmpty) {
            return null;
          }
          filtered.sort((a, b) => b.score.compareTo(a.score));
          return {
            'retrievedPreference': filtered
                .take(config.runtime.maxPreferenceResults)
                .map(
                  (match) => {'score': match.score, 'payload': match.payload},
                )
                .toList(),
          };
        } catch (_) {
          return null;
        }
      },
    );
    final jobSnapshotDispatcher = _JobSnapshotDispatcher();
    final jobManager = _ObservableJobManager(
      HiveJobManager(box: jobBox),
      jobSnapshotDispatcher,
    );
    final longTermMemory = DriftMemory.open(
      path: resolvedMemoryDbPath,
      summaryLimit: config.runtime.memorySummaryLimit,
    );
    final learningSwitch = SwitchableLearning(ThrowingLearning());
    final planningSwitch = SwitchablePlanning(ThrowingPlanning());
    if (llmConfig != null && llmConfigPool != null) {
      final llmDelegates = _buildLlmServiceDelegates(
        llmQueue: llmQueue,
        client: liteAgentClient,
        llmConfig: llmConfig,
        pool: llmConfigPool,
        mode: () => config.runtime.mode,
        modelProfiler: modelProfiler,
        supervision: supervision,
        preference: preference,
        openToolDirectory: openToolDirectory,
        logger: logger,
        runtimeConfig: config.runtime,
      );
      perceptionDelegateSwitch.delegate = llmDelegates.perception;
      planningSwitch.delegate = llmDelegates.planning;
      learningSwitch.delegate = llmDelegates.learning;
    }
    final kernel = _buildKernel(
      perception: perception,
      planning: planningSwitch,
      openToolDirectory: openToolDirectory,
      supervision: supervision,
      memory: longTermMemory,
      preference: preference,
      learning: learningSwitch,
      jobManager: jobManager,
      logger: logger,
    );

    var memorySummarizerStarted = false;
    if (config.runtime.memorySummaryEnabled &&
        llmConfig != null &&
        llmConfigPool != null) {
      MemorySummarizer(
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
        recentWindow: config.runtime.memorySummaryRecentWindow,
        maxRecords: config.runtime.memorySummaryMaxRecords,
        minRecords: config.runtime.memorySummaryMinRecords,
        maxScopesPerRun: config.runtime.memorySummaryMaxScopesPerRun,
        enabled: true,
      );
      memorySummarizerStarted = true;
    }
    return KernelService._internal(
      kernel,
      llmConfigPool: llmConfigPool,
      perceptionSwitch: perceptionDelegateSwitch,
      planningSwitch: planningSwitch,
      learningSwitch: learningSwitch,
      liteAgentClient: liteAgentClient,
      llmQueue: llmQueue,
      openToolDirectory: openToolDirectory,
      logger: logger,
      driftMemory: longTermMemory,
      preferenceVectorStore: vectorStore,
      memorySummarizerStarted: memorySummarizerStarted,
      jobSnapshotDispatcher: jobSnapshotDispatcher,
      runtimeConfig: config.runtime,
      opentoolDaemonHost: config.runtime.opentoolDaemonHost,
      opentoolDaemonPort: config.runtime.opentoolDaemonPort,
      embeddingsBaseUrl: config.embeddings.baseUrl,
      modelProfiler: modelProfiler,
    );
  }

  ConfirmationListener subscribeConfirmation({
    String? jobId,
    required void Function(String jobId) onNeedsConfirmation,
  }) {
    return _jobSnapshotDispatcher.add(
      jobId: jobId,
      onNeedsConfirmation: (snapshot) {
        if (snapshot.status != JobStatus.NEEDS_CONFIRMATION) {
          return;
        }
        onNeedsConfirmation(snapshot.jobId);
      },
    );
  }

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

  Future<void> recordAgentMessage({
    required String userId,
    required String bundleId,
    required AgentMessage agentMessage,
  }) async {
    final scope = 'bundle:$bundleId';
    final record = MemoryRecord(
      jobId: 'external-${DateTime.now().microsecondsSinceEpoch}',
      userId: userId,
      sessionId: agentMessage.sessionId,
      scope: scope,
      type: 'EXTERNAL_AGENT_MESSAGE',
      data: {
        'bundleId': bundleId,
        'userId': userId,
        'liteAgentSessionId': agentMessage.sessionId,
        'taskId': agentMessage.taskId,
        'agentMessage': _sanitizeJsonValue(agentMessage.toJson()),
      },
      timestamp: agentMessage.createTime,
    );
    await _kernel.memory.record(record);
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
    _restartExternalServiceMonitoring();
    unawaited(_restartOpenToolDaemonPresetSync());
  }

  Future<void> startOpenToolDaemonPresetSync({
    required String daemonApiKey,
    Duration debounce = const Duration(milliseconds: 200),
    DaemonPresetFilter? presetFilter,
  }) async {
    if (daemonApiKey.trim().isEmpty) {
      throw ArgumentError('daemonApiKey is required.');
    }
    final liteAgentClient = _liteAgentClient;
    if (liteAgentClient == null) {
      throw StateError('LiteAgent client is not managed by KernelService.');
    }
    _openToolDaemonSyncApiKey = daemonApiKey.trim();
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
      setPresetOpenSpecList: setPresetOpenSpecList,
      openToolDirectoryProvider: _resolveOpenToolDirectory,
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
    final perceptionSwitch = _perceptionSwitch;
    final planningSwitch = _planningSwitch;
    final learningSwitch = _learningSwitch;
    final liteAgentClient = _liteAgentClient;
    final llmQueue = _llmQueue;
    final openToolDirectory = _openToolDirectory;
    if (perceptionSwitch == null ||
        planningSwitch == null ||
        learningSwitch == null ||
        liteAgentClient == null ||
        llmQueue == null ||
        openToolDirectory == null) {
      throw StateError('LLM config is not managed by KernelService.');
    }
    final pool = _llmConfigPool;
    if (pool == null || pool.configs.isEmpty) {
      throw StateError('LLM config is not managed by KernelService.');
    }
    final llmConfig = pool.pick();
    final supervision = _kernel.supervision;
    final profiler = _modelProfiler;
    final llmDelegates = _buildLlmServiceDelegates(
      llmQueue: llmQueue,
      client: liteAgentClient,
      llmConfig: llmConfig,
      pool: pool,
      mode: () => _mode,
      modelProfiler: profiler,
      supervision: supervision,
      preference: _kernel.preference,
      openToolDirectory: openToolDirectory,
      logger: _logger,
      runtimeConfig: _runtimeConfig,
    );
    perceptionSwitch.delegate = llmDelegates.perception;
    planningSwitch.delegate = llmDelegates.planning;
    learningSwitch.delegate = llmDelegates.learning;
    if (_runtimeConfig.memorySummaryEnabled &&
        !_memorySummarizerStarted &&
        _driftMemory != null) {
      MemorySummarizer(
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
        recentWindow: _runtimeConfig.memorySummaryRecentWindow,
        maxRecords: _runtimeConfig.memorySummaryMaxRecords,
        minRecords: _runtimeConfig.memorySummaryMinRecords,
        maxScopesPerRun: _runtimeConfig.memorySummaryMaxScopesPerRun,
        enabled: true,
      );
      _memorySummarizerStarted = true;
    }
  }

  Future<bool> updateEmbeddingsConfig(EmbeddingsConfig config) async {
    final vectorStore = _preferenceVectorStore;
    if (vectorStore == null) {
      throw StateError('Embeddings config is not managed by KernelService.');
    }

    final pool = _llmConfigPool;
    if (pool == null || pool.configs.isEmpty) {
      vectorStore.delegate = ThrowingTextQueryVectorStore();
      return false;
    }

    final candidate = _resolveEmbeddingsLlmConfig(config, pool);
    if (candidate == null) {
      vectorStore.delegate = ThrowingTextQueryVectorStore();
      return false;
    }

    final embeddingsClient = embeddings.LiteEmbeddingsClient(
      baseUrl: config.baseUrl,
      bearerToken: config.apiKey,
    );
    final embeddingsLlmConfig = embeddings.LLMConfig(
      baseUrl: candidate.baseUrl,
      apiKey: candidate.apiKey ?? '',
      model: _resolveEmbeddingsModel(config.model, candidate.model),
    );

    try {
      final docsId = await _ensureDocsId(
        embeddingsClient,
        config.docsName,
        embeddingsLlmConfig,
      );
      vectorStore.delegate = LiteEmbeddingsVectorStore(
        client: embeddingsClient,
        docsId: docsId,
        llmConfig: embeddingsLlmConfig,
      );
      _restartEmbeddingsHealthMonitoring(config.baseUrl);
      return true;
    } catch (_) {
      vectorStore.delegate = ThrowingTextQueryVectorStore();
      return false;
    }
  }

  LLMConfig? _resolveEmbeddingsLlmConfig(
    EmbeddingsConfig config,
    LlmConfigPool pool,
  ) {
    final preferred = config.llmModel?.trim();
    if (preferred != null && preferred.isNotEmpty) {
      for (final candidate in pool.configs) {
        if (candidate.model == preferred) {
          return candidate;
        }
      }
      return null;
    }
    final available = getAvailableLlmConfig();
    return available ?? pool.pick();
  }

  void _restartEmbeddingsHealthMonitoring(String baseUrl) {
    _embeddingsBaseUrl = baseUrl;
    _restartExternalServiceMonitoring();
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
      embeddingsBaseUrl: _embeddingsBaseUrl,
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
    bool requireEmbeddings = false,
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
    final embeddingsReady = _hasHealthyExternalService(
      health,
      ExternalServiceType.embeddings,
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
    if (requireEmbeddings && !embeddingsReady) {
      reasons.add('Embeddings service is not healthy yet.');
    }

    return KernelReadiness(
      ready: reasons.isEmpty,
      llmConfigured: llmConfigured,
      llmServicesReady: llmServicesReady,
      liteAgentReady: liteAgentReady,
      openToolDaemonReady: openToolDaemonReady,
      embeddingsReady: embeddingsReady,
      reasons: reasons,
    );
  }

  bool isReady({
    bool requireLlm = true,
    bool requireLiteAgent = true,
    bool requireOpenToolDaemon = false,
    bool requireEmbeddings = false,
  }) {
    final readiness = getReadiness(
      requireLlm: requireLlm,
      requireLiteAgent: requireLiteAgent,
      requireOpenToolDaemon: requireOpenToolDaemon,
      requireEmbeddings: requireEmbeddings,
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
    final perception = _perceptionSwitch;
    final planning = _planningSwitch;
    final learning = _learningSwitch;
    if (perception == null || planning == null || learning == null) {
      return false;
    }
    return perception.delegate is! ThrowingPerception &&
        planning.delegate is! ThrowingPlanning &&
        learning.delegate is! ThrowingLearning;
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

  /// Get memory snapshot for a scope.
  ///
  /// [scope] typically matches the source.
  /// [limit] caps the number of recent records returned.
  Future<MemorySnapshot> getMemorySnapshot({
    required String scope,
    int limit = 20,
  }) async {
    final snapshot = await _kernel.memory.getSnapshot(scope: scope);
    final records = _recentMemory(snapshot.records, limit);
    return MemorySnapshot(
      scope: snapshot.scope,
      data: snapshot.data,
      records: records,
    );
  }

  /// Get preference snapshot for the default user.
  Future<PreferenceSnapshot> getPreferenceSnapshot() {
    const userId = _defaultUserId;
    return _kernel.preference.getSnapshot(userId: userId);
  }

  /// List memory records for management UI.
  ///
  /// Returns paged summary records with deletion ids.
  Future<List<MemoryRecordListItem>> listMemoryRecords({
    int pageNum = 0,
    int pageSize = 50,
  }) async {
    if (pageNum < 0) {
      throw ArgumentError.value(pageNum, 'pageNum', 'must be non-negative');
    }
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }
    final records = await _kernel.memory.listRecords(
      type: 'MEMORY_SUMMARY',
      includeSummaries: true,
      offset: pageNum * pageSize,
      limit: pageSize,
    );
    return records
        .where((record) => record.id != null)
        .map(
          (record) => MemoryRecordListItem(
            id: record.id!,
            text: _memorySummaryText(record),
            timestamp: record.timestamp,
          ),
        )
        .toList(growable: false);
  }

  Future<void> deleteMemoryRecord(String id) {
    return _kernel.memory.deleteRecord(id);
  }

  /// List preference entries for management UI.
  Future<List<PreferenceListItem>> listPreferenceItems({
    String userId = _defaultUserId,
  }) async {
    final preferences = await _kernel.preference.listPreferences(
      userId: userId,
    );
    return preferences.entries
        .where((entry) => entry.key != 'signals')
        .map(
          (entry) => PreferenceListItem(
            key: entry.key,
            text: _preferenceItemText(entry.key, entry.value),
          ),
        )
        .toList(growable: false);
  }

  Future<void> deletePreferenceKey(String key, {String? userId}) {
    return _kernel.preference.deletePreferenceKey(
      key,
      userId: userId ?? _defaultUserId,
    );
  }

  /// Suggest next action when there is no user input.
  ///
  /// [source] identifies the caller or channel.
  /// [allowedActions] limits which actions can be suggested.
  /// [memoryLimit] controls how many recent memory records are exposed.
  Future<IntentResponseDto> suggestNextAction({
    required String source,
    List<String>? allowedActions,
    int memoryLimit = 5,
  }) async {
    const userId = _defaultUserId;
    final memorySnapshot = await _kernel.memory.getSnapshot(scope: source);
    final preferenceSnapshot = await _kernel.preference.getSnapshot(
      userId: userId,
    );
    final directory = _resolveOpenToolDirectory();
    final toolSummaries = directory.isEmpty
        ? const []
        : await directory.summaries();
    final recentRecords = _recentMemory(memorySnapshot.records, memoryLimit);
    final data = <String, dynamic>{
      'mode': 'suggestion',
      'memoryScope': memorySnapshot.scope,
      'recentMemory': recentRecords
          .map(
            (record) => {
              'type': record.type,
              'data': record.data,
              'timestamp': record.timestamp.toIso8601String(),
            },
          )
          .toList(),
      'preferences': preferenceSnapshot.preferences,
      'availableTools': toolSummaries,
      if (allowedActions != null && allowedActions.isNotEmpty)
        'allowedActions': allowedActions,
    };
    final percept = await _kernel.perception.process(
      RawInput(userId: userId, source: source, data: data),
    );
    final candidates = percept.candidates
        .map(
          (candidate) => IntentCandidateDto(
            action: candidate.action,
            payload: {
              if (candidate.target != null) 'target': candidate.target,
              if (candidate.params != null) ...candidate.params!,
            },
            confidence: candidate.confidence,
          ),
        )
        .toList();
    return IntentResponseDto(candidates: candidates);
  }

  /// Submit a raw input.
  ///
  /// [source] identifies the caller or channel (e.g., KernelSources.cli).
  /// [content] is the LiteAgent Content list; text is derived from it.
  /// [data] carries additional structured payload.
  ///
  /// Returns a [JobHandle] for status tracking or confirmation.
  JobHandle submitRaw({
    required String source,
    required List<Content> content,
    Map<String, dynamic>? data,
  }) {
    const userId = _defaultUserId;
    final runner = _perceptionRunner;
    if (runner != null) {
      return runner.submitRaw(
        source: source,
        content: content,
        data: data,
        userId: userId,
      );
    }
    final derivedText = _contentToText(content);
    if (derivedText == null || derivedText.trim().isEmpty) {
      throw ArgumentError('content is required.');
    }
    return _kernel.input(
      RawInput(
        userId: userId,
        source: source,
        text: derivedText,
        data: _mergeContent(data, content),
      ),
    );
  }

  /// Submit a selected intent candidate (action + payload).
  ///
  /// [source] identifies the caller or channel (e.g., KernelSources.api).
  /// [intent] is the chosen intent candidate.
  JobHandle submitIntent({
    required String source,
    required IntentCandidateDto intent,
  }) {
    const userId = _defaultUserId;
    final target = intent.payload['target'];
    return _kernel.input(
      RawInput(
        userId: userId,
        source: source,
        data: {
          'action': intent.action,
          if (target is String) 'target': target,
          'params': intent.payload,
        },
      ),
    );
  }

  /// Confirm or reject a pending job that requires user confirmation.
  ///
  /// [jobId] is the job awaiting confirmation.
  /// [confirmed] true to proceed, false to cancel.
  JobHandle confirmJob(String jobId, {required bool confirmed}) {
    return _kernel.confirmJob(jobId, confirmed: confirmed);
  }

  // Job snapshots are intentionally not exposed. Use confirmation callbacks
  // for user-gated actions instead of polling job status.

  /// Register a local OpenTool handler (callback tool).
  ///
  /// [tool] is the local OpenTool Tool implementation.
  /// Tool id is derived from the OpenTool spec (info.title).
  void registerLocalOpenTool(Tool tool) {
    final directory = _resolveOpenToolDirectory();
    directory.registerLocal(tool);
  }

  /// Register a remote OpenTool (OpenTool Server).
  ///
  /// [spec] is the OpenTool specification.
  /// [serverUrl] overrides the spec's server url.
  /// [apiKey] is used when calling the remote OpenTool.
  String registerRemoteOpenTool(
    OpenTool spec, {
    String? serverUrl,
    String? apiKey,
  }) {
    final directory = _resolveOpenToolDirectory();
    return directory.registerRemote(spec, serverUrl: serverUrl, apiKey: apiKey);
  }

  bool updateRemoteOpenToolEndpoint(
    String toolId, {
    String? serverUrl,
    String? apiKey,
  }) {
    if ((serverUrl == null || serverUrl.trim().isEmpty) && apiKey == null) {
      throw ArgumentError('Either serverUrl or apiKey is required.');
    }
    final directory = _resolveOpenToolDirectory();
    return directory.updateRemoteEndpoint(
      toolId,
      serverUrl: serverUrl,
      apiKey: apiKey,
    );
  }

  void updateAppInfoList(List<AppInfo> apps) {
    final tool = _ensureAppCalledTool();
    tool.updateApps(apps);
    final directory = _resolveOpenToolDirectory();
    directory.updateLocalToolSpec(
      tool,
      tool.buildSpec(),
      toolId: AppCalledTool.toolId,
    );
  }

  void setAppCalledHandler(AppCalledHandler handler) {
    final tool = _ensureAppCalledTool();
    tool.updateHandler(handler);
  }

  // Debug/admin accessors live in KernelAdminService.

  static Kernel _buildKernel({
    required Perception perception,
    required Planning planning,
    required OpenToolDirectory openToolDirectory,
    required Supervision supervision,
    required DriftMemory memory,
    required Preference preference,
    required Learning learning,
    required JobManager jobManager,
    required KernelLogger logger,
  }) {
    return Kernel(
      perception: perception,
      planning: planning,
      execution: OpenToolExecution(openToolDirectory: openToolDirectory),
      supervision: supervision,
      memory: memory,
      preference: preference,
      learning: learning,
      jobManager: jobManager,
      logger: logger,
    );
  }

  static _LlmServiceDelegates _buildLlmServiceDelegates({
    required LlmQueue llmQueue,
    required LiteAgentClient client,
    required LLMConfig llmConfig,
    required LlmConfigPool pool,
    required KernelMode Function() mode,
    required ModelProfiler? modelProfiler,
    required Supervision supervision,
    required Preference preference,
    required OpenToolDirectory openToolDirectory,
    required KernelLogger? logger,
    required KernelRuntimeConfig runtimeConfig,
  }) {
    final perception = LiteAgentPerception(
      llmQueue: llmQueue,
      client: client,
      llmConfig: llmConfig,
      llmConfigResolver: _makeResolver(
        llmQueue: llmQueue,
        pool: pool,
        purpose: 'perception',
        mode: mode,
        profiler: modelProfiler,
        supervision: supervision,
        runtimeConfig: runtimeConfig,
      ),
      systemPrompt:
          'You are an intent extractor. Use emit_intent or reject_intent.',
      actionHints: const [
        'count',
        'create',
        'read',
        'list',
        'sequentiallyRead',
        'update',
        'delete',
        'run',
      ],
      fallback: RuleBasedPerception(),
    );
    final planning = LiteAgentPlanning(
      llmQueue: llmQueue,
      client: client,
      llmConfig: llmConfig,
      llmConfigResolver: _makeResolver(
        pool: pool,
        purpose: 'planning',
        mode: mode,
        profiler: modelProfiler,
        supervision: supervision,
        runtimeConfig: runtimeConfig,
      ),
      systemPrompt: 'You plan the next action. Call exactly one planning tool.',
      openToolDirectory: openToolDirectory,
    );
    final liteAgentLearning = LiteAgentLearning(
      llmQueue: llmQueue,
      client: client,
      preference: preference,
      llmConfig: llmConfig,
      llmConfigResolver: _makeResolver(
        pool: pool,
        purpose: 'learning',
        mode: mode,
        profiler: modelProfiler,
        supervision: supervision,
        runtimeConfig: runtimeConfig,
      ),
      systemPrompt:
          'You extract user preference signals. Use emit_preference or reject_preference.',
    );
    final learning = DeferredLearning(
      delegate: liteAgentLearning,
      llmQueue: llmQueue,
      logger: logger,
      enabled: runtimeConfig.learningDeferredEnabled,
      interval: runtimeConfig.learningInterval,
      maxPerRun: runtimeConfig.learningMaxPerRun,
      queueLimit: runtimeConfig.learningQueueLimit,
    );
    return _LlmServiceDelegates(
      perception: perception,
      planning: planning,
      learning: learning,
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

  Map<String, dynamic>? _mergeContent(
    Map<String, dynamic>? data,
    List<Content>? content,
  ) {
    if (content == null || content.isEmpty) {
      return data;
    }
    final merged = <String, dynamic>{};
    if (data != null) {
      merged.addAll(data);
    }
    merged['content'] = content.map((item) => item.toJson()).toList();
    return merged;
  }

  String? _contentToText(List<Content>? content) {
    if (content == null || content.isEmpty) {
      return null;
    }
    return content.map((item) => item.message).join('\n');
  }

  OpenToolDirectory _resolveOpenToolDirectory() {
    OpenToolDirectory? fromPlanning;
    final planning = _kernel.planning;
    if (planning is RuleBasedPlanning) {
      fromPlanning = planning.openToolDirectory;
    } else if (planning is LiteAgentPlanning) {
      fromPlanning = planning.openToolDirectory;
    }

    OpenToolDirectory? fromExecution;
    final execution = _kernel.execution;
    if (execution is OpenToolExecution) {
      fromExecution = execution.openToolDirectory;
    }

    if (fromPlanning != null &&
        fromExecution != null &&
        !identical(fromPlanning, fromExecution)) {
      throw StateError(
        'OpenToolDirectory mismatch between planning and execution.',
      );
    }
    final directory = fromPlanning ?? fromExecution;
    if (directory == null) {
      throw StateError('OpenToolDirectory not configured on kernel.');
    }
    return directory;
  }

  List<MemoryRecord> _recentMemory(List<MemoryRecord> records, int limit) {
    final summaries = records
        .where((record) => record.type == 'MEMORY_SUMMARY')
        .toList();
    final details = records
        .where((record) => record.type != 'MEMORY_SUMMARY')
        .toList();
    final detailSlice = (limit <= 0 || details.length <= limit)
        ? details
        : details.sublist(details.length - limit);
    final summaryLimit = _runtimeConfig.memorySummaryLimit;
    final summarySlice = (summaryLimit <= 0 || summaries.length <= summaryLimit)
        ? summaries
        : summaries.sublist(summaries.length - summaryLimit);
    final combined = [...summarySlice, ...detailSlice];
    combined.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return combined;
  }

  String _memorySummaryText(MemoryRecord record) {
    final data = record.data;
    if (data != null) {
      final summaryText = _firstNonEmptyString(const ['summaryText'], data);
      if (summaryText != null) {
        return summaryText;
      }
      final keyFacts = data['keyFacts'];
      if (keyFacts is List) {
        final text = keyFacts
            .map((item) => item is String ? item.trim() : '')
            .where((item) => item.isNotEmpty)
            .join('\n');
        if (text.isNotEmpty) {
          return text;
        }
      }
    }
    return 'Memory summary';
  }

  String _preferenceItemText(String key, Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      return value;
    }
    if (value is List) {
      final text = value
          .map((item) => item is String ? item.trim() : '')
          .where((item) => item.isNotEmpty)
          .join(', ');
      if (text.isNotEmpty) {
        return text;
      }
    }
    final encoded = _encodeCompactJson(value);
    if (encoded != null && encoded.isNotEmpty) {
      return '$key: $encoded';
    }
    return key;
  }

  String? _firstNonEmptyString(List<String> keys, Map<String, dynamic> data) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  String? _encodeCompactJson(Object? value) {
    if (value == null) {
      return null;
    }
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }

  AppCalledTool _ensureAppCalledTool() {
    final existing = _appCalledTool;
    if (existing != null) {
      return existing;
    }
    final tool = AppCalledTool();
    final directory = _resolveOpenToolDirectory();
    directory.registerLocal(tool, toolId: AppCalledTool.toolId);
    _appCalledTool = tool;
    return tool;
  }

  Object? _sanitizeJsonValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is num || value is String || value is bool) {
      return value;
    }
    if (value is Map) {
      final mapped = <String, dynamic>{};
      value.forEach((key, entry) {
        mapped[key.toString()] = _sanitizeJsonValue(entry);
      });
      return mapped;
    }
    if (value is Iterable) {
      return value.map(_sanitizeJsonValue).toList(growable: false);
    }
    try {
      return jsonDecode(jsonEncode(value));
    } catch (_) {
      return value.toString();
    }
  }
}

class ConfirmationListener {
  final void Function() _cancel;

  ConfirmationListener._(this._cancel);

  Future<void> cancel() {
    _cancel();
    return Future.value();
  }
}

class _JobSnapshotListenerEntry {
  final String? jobId;
  final void Function(JobSnapshot snapshot) onNeedsConfirmation;
  bool _active = true;

  _JobSnapshotListenerEntry({
    required this.jobId,
    required this.onNeedsConfirmation,
  });

  bool get active => _active;

  void emit(JobSnapshot snapshot) {
    if (!_active) {
      return;
    }
    if (jobId != null && jobId!.isNotEmpty && snapshot.jobId != jobId) {
      return;
    }
    onNeedsConfirmation(snapshot);
  }

  void cancel() {
    if (!_active) {
      return;
    }
    _active = false;
  }
}

class _JobSnapshotDispatcher {
  final List<_JobSnapshotListenerEntry> _listeners = [];

  ConfirmationListener add({
    String? jobId,
    required void Function(JobSnapshot snapshot) onNeedsConfirmation,
  }) {
    final entry = _JobSnapshotListenerEntry(
      jobId: jobId,
      onNeedsConfirmation: onNeedsConfirmation,
    );
    _listeners.add(entry);
    return ConfirmationListener._(() {
      entry.cancel();
      _listeners.remove(entry);
    });
  }

  void notify(JobSnapshot snapshot) {
    if (_listeners.isEmpty) {
      return;
    }
    final snapshotListeners = List<_JobSnapshotListenerEntry>.from(_listeners);
    for (final entry in snapshotListeners) {
      entry.emit(snapshot);
      if (!entry.active) {
        _listeners.remove(entry);
      }
    }
  }
}

KernelLlmModel _resolveEmbeddingsLlmModel(
  List<KernelLlmModel> models,
  String? embeddingsModel,
) {
  if (models.isEmpty) {
    throw ArgumentError('llmModels is required.');
  }
  if (embeddingsModel == null || embeddingsModel.trim().isEmpty) {
    return models.first;
  }
  for (final model in models) {
    if (model.model == embeddingsModel) {
      return model;
    }
  }
  throw ArgumentError('embeddingsLlmModel is not found in llmModels.');
}

String _resolveEmbeddingsModel(String? model, String fallback) {
  if (model == null || model.trim().isEmpty) {
    return fallback;
  }
  return model;
}

bool _isRelevantMatch(VectorMatch match, double maxDistance) {
  final distance = match.payload?['distance'];
  if (distance is num) {
    return distance <= maxDistance;
  }
  return match.score >= -maxDistance;
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

Future<String> _ensureDocsId(
  embeddings.LiteEmbeddingsClient client,
  String docsName,
  embeddings.LLMConfig llmConfig,
) async {
  final docsList = await client.listDocs();
  for (final docs in docsList) {
    if (docs.docsName == docsName) {
      return docs.docsId;
    }
  }
  final created = await client.createDocs(
    embeddings.CreateDocsRequest(
      docsName: docsName,
      segmentList: [
        embeddings.Segment(
          text: 'bootstrap',
          metadata: const {'bootstrap': true},
        ),
      ],
      llmConfig: llmConfig,
    ),
  );
  return created.docsId;
}

class _OpenToolDaemonPresetSync {
  final String Function() hostProvider;
  final int Function() portProvider;
  final String daemonApiKey;
  final Duration debounce;
  final DaemonPresetFilter? presetFilter;
  final Future<void> Function(List<PresetOpenSpec>) setPresetOpenSpecList;
  final OpenToolDirectory Function() openToolDirectoryProvider;
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
    required this.setPresetOpenSpecList,
    required this.openToolDirectoryProvider,
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
    try {
      await setPresetOpenSpecList(const []);
    } catch (_) {
      // Ignore cleanup failures while shutting down the sync bridge.
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
    final presetList = activeTools
        .where((tool) => presetFilter?.call(tool.toPresetCandidate()) ?? true)
        .map((tool) => tool.preset)
        .toList();
    final directory = openToolDirectoryProvider();
    final nextDirectoryToolIds = <String>{};
    for (final tool in activeTools) {
      final directoryToolId = _directoryToolId(tool.toolId);
      nextDirectoryToolIds.add(directoryToolId);
      directory.registerRemote(
        tool.spec,
        toolId: directoryToolId,
        serverUrl: tool.serverUrl,
        apiKey: tool.apiKey,
      );
    }
    for (final toolId in _directoryToolIds.difference(nextDirectoryToolIds)) {
      directory.unregister(toolId);
    }
    _directoryToolIds
      ..clear()
      ..addAll(nextDirectoryToolIds);
    await setPresetOpenSpecList(presetList);
  }

  void _clearDirectoryTools() {
    final directory = openToolDirectoryProvider();
    for (final toolId in _directoryToolIds) {
      directory.unregister(toolId);
    }
    _directoryToolIds.clear();
  }

  DaemonClient _client() =>
      DaemonClient(host: hostProvider(), port: portProvider());

  String _directoryToolId(String toolId) => 'daemon:$toolId';
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

class _ObservableJobManager implements JobManager {
  final JobManager _delegate;
  final _JobSnapshotDispatcher _snapshots;

  _ObservableJobManager(this._delegate, this._snapshots);

  @override
  JobHandle createJob({
    required String source,
    String? userId,
    String? sessionId,
  }) {
    final handle = _delegate.createJob(
      source: source,
      userId: userId,
      sessionId: sessionId,
    );
    _emitSnapshot(handle.jobId);
    return handle;
  }

  @override
  JobHandle markQueued(String jobId) {
    final handle = _delegate.markQueued(jobId);
    _emitSnapshot(jobId);
    return handle;
  }

  @override
  JobHandle markRunning(String jobId) {
    final handle = _delegate.markRunning(jobId);
    _emitSnapshot(jobId);
    return handle;
  }

  @override
  JobHandle markDone(String jobId, JobResult result) {
    final handle = _delegate.markDone(jobId, result);
    _emitSnapshot(jobId);
    return handle;
  }

  @override
  JobHandle markFailed(String jobId, String reason) {
    final handle = _delegate.markFailed(jobId, reason);
    _emitSnapshot(jobId);
    return handle;
  }

  @override
  JobHandle markNeedsConfirmation(
    String jobId,
    JobPrompt prompt,
    Intent intent,
  ) {
    final handle = _delegate.markNeedsConfirmation(jobId, prompt, intent);
    _emitSnapshot(jobId);
    return handle;
  }

  @override
  JobHandle cancel(String jobId, {String? reason}) {
    final handle = _delegate.cancel(jobId, reason: reason);
    _emitSnapshot(jobId);
    return handle;
  }

  @override
  JobHandle getHandle(String jobId) => _delegate.getHandle(jobId);

  @override
  JobStatus getStatus(String jobId) => _delegate.getStatus(jobId);

  @override
  JobSnapshot getSnapshot(String jobId) => _delegate.getSnapshot(jobId);

  void _emitSnapshot(String jobId) {
    try {
      final snapshot = _delegate.getSnapshot(jobId);
      _snapshots.notify(snapshot);
    } catch (_) {
      // Ignore missing job snapshots.
    }
  }
}
