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
import '../kernel/preference/lite_embeddings_vector_store.dart';
import '../kernel/preference/vector_store.dart';
import '../kernel/supervision/model.dart';
import '../kernel/supervision/supervision.dart';
import 'dto.dart';

class LiteAgentConfig {
  final String baseUrl;
  final String? apiKey;

  const LiteAgentConfig({required this.baseUrl, this.apiKey});
}

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
  });
}

class KernelServiceConfig {
  final LiteAgentConfig liteAgent;
  final LlmConfigGroup? llm;
  final EmbeddingsConfig embeddings;
  final KernelRuntimeConfig runtime;

  const KernelServiceConfig({
    required this.liteAgent,
    this.llm,
    required this.embeddings,
    this.runtime = const KernelRuntimeConfig(),
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
  bool _memorySummarizerStarted;
  final _JobSnapshotDispatcher _jobSnapshotDispatcher;
  AppCalledTool? _appCalledTool;
  final KernelRuntimeConfig _runtimeConfig;

  /// Wraps the kernel with a simplified API for external callers.
  KernelService(
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
    bool memorySummarizerStarted = false,
    _JobSnapshotDispatcher? jobSnapshotDispatcher,
    KernelRuntimeConfig runtimeConfig = const KernelRuntimeConfig(),
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
       _memorySummarizerStarted = memorySummarizerStarted,
       _jobSnapshotDispatcher =
           jobSnapshotDispatcher ?? _JobSnapshotDispatcher(),
       _runtimeConfig = runtimeConfig;

  String get defaultUserId => _defaultUserId;

  String getCurrentUserId() => _defaultUserId;

  static Future<KernelService> create(KernelServiceConfig config) async {
    final supervision = AdaptiveSupervision(
      ttftThreshold: config.runtime.ttftThreshold,
      tpsThreshold: config.runtime.tpsThreshold,
      maxConcurrency: config.runtime.maxConcurrency,
    );

    final logger = ConsoleKernelLogger();
    final llmQueue = LlmQueue(supervision: supervision, logger: logger);

    final liteAgentClient = LiteAgentClient(
      baseUrl: config.liteAgent.baseUrl,
      apiKey: config.liteAgent.apiKey,
    );
    supervision.startExternalServiceMonitoring(
      liteAgentBaseUrl: config.liteAgent.baseUrl,
      opentoolHost: config.runtime.opentoolDaemonHost,
      opentoolPort: config.runtime.opentoolDaemonPort,
      embeddingsBaseUrl: config.embeddings.baseUrl,
    );

    LlmConfigPool? llmConfigPool;
    LlmConfigResolver? llmConfigResolver;
    LLMConfig? llmConfig;
    final llmModels = config.llm?.models ?? const <KernelLlmModel>[];
    if (llmModels.isNotEmpty) {
      final llmConfigs = llmModels
          .map(
            (model) => LLMConfig(
              baseUrl: model.baseUrl,
              apiKey: model.apiKey ?? '',
              model: model.model,
              contextWindowSize: model.contextWindowSize,
            ),
          )
          .toList();
      llmConfigPool = LlmConfigPool(llmConfigs);
      supervision.updateModelCatalog(llmModels);
      llmConfig = llmConfigPool.pick();
      llmConfigResolver = () => llmConfigPool!.pick(
        isAvailable: (candidate) => _isModelAvailable(supervision, candidate),
      );
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
    if (llmConfig != null && llmConfigResolver != null) {
      perceptionDelegateSwitch.delegate = LiteAgentPerception(
        llmQueue: llmQueue,
        client: liteAgentClient,
        llmConfig: llmConfig,
        llmConfigResolver: llmConfigResolver,
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
      planningSwitch.delegate = LiteAgentPlanning(
        llmQueue: llmQueue,
        client: liteAgentClient,
        llmConfig: llmConfig,
        llmConfigResolver: llmConfigResolver,
        systemPrompt:
            'You plan the next action. Call exactly one planning tool.',
        openToolDirectory: openToolDirectory,
      );
      final liteAgentLearning = LiteAgentLearning(
        llmQueue: llmQueue,
        client: liteAgentClient,
        preference: preference,
        llmConfig: llmConfig,
        llmConfigResolver: llmConfigResolver,
        systemPrompt:
            'You extract user preference signals. Use emit_preference or reject_preference.',
      );
      learningSwitch.delegate = DeferredLearning(
        delegate: liteAgentLearning,
        llmQueue: llmQueue,
        logger: logger,
        enabled: config.runtime.learningDeferredEnabled,
        interval: config.runtime.learningInterval,
        maxPerRun: config.runtime.learningMaxPerRun,
        queueLimit: config.runtime.learningQueueLimit,
      );
    }
    final kernel = Kernel(
      perception: perception,
      planning: planningSwitch,
      execution: OpenToolExecution(openToolDirectory: openToolDirectory),
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
        llmConfigResolver != null) {
      MemorySummarizer(
        memory: longTermMemory,
        llmQueue: llmQueue,
        client: liteAgentClient,
        llmConfig: llmConfig,
        llmConfigResolver: llmConfigResolver,
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
    return KernelService(
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
      memorySummarizerStarted: memorySummarizerStarted,
      jobSnapshotDispatcher: jobSnapshotDispatcher,
      runtimeConfig: config.runtime,
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

  void updateLlmModels(List<KernelLlmModel> models) {
    if (models.isEmpty) {
      throw ArgumentError('models is required.');
    }
    final configs = models
        .map(
          (model) => LLMConfig(
            baseUrl: model.baseUrl,
            apiKey: model.apiKey ?? '',
            model: model.model,
            contextWindowSize: model.contextWindowSize,
          ),
        )
        .toList();
    var pool = _llmConfigPool;
    if (pool == null) {
      pool = LlmConfigPool(configs);
      _llmConfigPool = pool;
    } else {
      pool.update(configs);
    }
    final supervision = _kernel.supervision;
    if (supervision is AdaptiveSupervision) {
      supervision.updateModelCatalog(models);
      supervision.startLlmHealthMonitoring(models);
    }

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
    final llmConfig = pool.pick();
    final llmConfigResolver = () => pool!.pick(
      isAvailable: (candidate) =>
          _isModelAvailable(_kernel.supervision, candidate),
    );
    perceptionSwitch.delegate = LiteAgentPerception(
      llmQueue: llmQueue,
      client: liteAgentClient,
      llmConfig: llmConfig,
      llmConfigResolver: llmConfigResolver,
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
    planningSwitch.delegate = LiteAgentPlanning(
      llmQueue: llmQueue,
      client: liteAgentClient,
      llmConfig: llmConfig,
      llmConfigResolver: llmConfigResolver,
      systemPrompt: 'You plan the next action. Call exactly one planning tool.',
      openToolDirectory: openToolDirectory,
    );
    final liteAgentLearning = LiteAgentLearning(
      llmQueue: llmQueue,
      client: liteAgentClient,
      preference: _kernel.preference,
      llmConfig: llmConfig,
      llmConfigResolver: llmConfigResolver,
      systemPrompt:
          'You extract user preference signals. Use emit_preference or reject_preference.',
    );
    learningSwitch.delegate = DeferredLearning(
      delegate: liteAgentLearning,
      llmQueue: llmQueue,
      logger: _logger,
      enabled: _runtimeConfig.learningDeferredEnabled,
      interval: _runtimeConfig.learningInterval,
      maxPerRun: _runtimeConfig.learningMaxPerRun,
      queueLimit: _runtimeConfig.learningQueueLimit,
    );
    if (_runtimeConfig.memorySummaryEnabled &&
        !_memorySummarizerStarted &&
        _driftMemory != null) {
      MemorySummarizer(
        memory: _driftMemory,
        llmQueue: llmQueue,
        client: liteAgentClient,
        llmConfig: llmConfig,
        llmConfigResolver: llmConfigResolver,
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

  Map<String, ModelHealthSnapshot> getModelHealth() {
    final supervision = _kernel.supervision;
    if (supervision is AdaptiveSupervision) {
      return supervision.modelHealthSnapshot();
    }
    return const {};
  }

  /// Pick the currently available LLM config for external callers.
  ///
  /// Availability is decided by supervision model health and current
  /// per-model concurrency/load. Returns null when no model can take
  /// new requests at the moment.
  LLMConfig? getAvailableLlmConfig() {
    final pool = _llmConfigPool;
    if (pool == null || pool.configs.isEmpty) {
      return null;
    }
    final queue = _llmQueue;
    final supervision = _kernel.supervision;
    for (final candidate in pool.configs) {
      if (!_isModelAvailable(supervision, candidate)) {
        continue;
      }
      if (queue == null) {
        return candidate;
      }
      final modelKey = buildLlmModelKey(
        baseUrl: candidate.baseUrl,
        model: candidate.model,
        apiKey: candidate.apiKey,
      );
      final snapshot = queue.snapshotForModel(modelKey);
      final maxConcurrency = supervision.recommendedLlmConcurrency(
        snapshot,
        modelKey,
      );
      if (maxConcurrency > 0 && snapshot.inFlight < maxConcurrency) {
        return candidate;
      }
    }
    return null;
  }

  ExternalServiceHealthSnapshot getExternalServiceHealth() {
    final supervision = _kernel.supervision;
    if (supervision is AdaptiveSupervision) {
      return supervision.externalServiceHealthSnapshot();
    }
    return const ExternalServiceHealthSnapshot(items: {});
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
