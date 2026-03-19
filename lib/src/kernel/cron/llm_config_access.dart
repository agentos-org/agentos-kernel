import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import '../agent/config.dart';
import '../agent/llm_queue.dart';
import '../agent/model.dart';
import '../supervision/model_profiler.dart';
import '../supervision/supervision.dart';

class CronLlmConfigAccess {
  LlmConfigPool? pool;
  final LlmQueue? llmQueue;
  final Supervision supervision;
  final ModelProfiler? profiler;
  KernelMode mode;
  final double profileSuccessRateThreshold;
  final String purpose;

  CronLlmConfigAccess({
    required this.pool,
    required this.llmQueue,
    required this.supervision,
    required this.profiler,
    required this.mode,
    required this.profileSuccessRateThreshold,
    required this.purpose,
  });

  LLMConfig? resolve() {
    final currentPool = pool;
    if (currentPool == null || currentPool.configs.isEmpty) {
      return null;
    }
    final adaptiveSupervision = supervision is AdaptiveSupervision
        ? supervision as AdaptiveSupervision
        : null;
    final modelCatalog =
        adaptiveSupervision?.modelCatalog ?? const <String, KernelLlmModel>{};
    final picked = currentPool.pickForPurpose(
      mode: mode,
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
      successRateThreshold: profileSuccessRateThreshold,
    );
    if (picked != null) {
      return picked;
    }
    final relaxed = currentPool.pickForPurpose(
      mode: mode,
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
      successRateThreshold: profileSuccessRateThreshold,
      allowProfilerSkip: false,
    );
    if (relaxed != null) {
      return relaxed;
    }
    return currentPool.pick(
      isAvailable: (candidate) =>
          _isModelAvailable(supervision, candidate) &&
          _hasQueueCapacity(
            supervision: supervision,
            llmQueue: llmQueue,
            candidate: candidate,
            requireCapacity: purpose == 'perception',
          ),
    );
  }

  List<LLMConfig> resolveAll() {
    return pool?.configs ?? const <LLMConfig>[];
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

bool _hasQueueCapacity({
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
