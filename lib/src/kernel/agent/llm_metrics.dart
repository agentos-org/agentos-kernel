import '../supervision/supervision.dart';
import 'model.dart';

class SupervisionLlmMetricsSink {
  final Supervision _supervision;
  final String _modelKey;
  final String _purpose;
  final int _priority;
  final int _weight;
  final String? _jobId;
  final String? _userId;

  final Map<String, _ExternalLlmRequestState> _requests = {};

  SupervisionLlmMetricsSink({
    required Supervision supervision,
    required String baseUrl,
    required String model,
    required String apiKey,
    String purpose = 'external_llm',
    int priority = 0,
    int weight = 1,
    String? jobId,
    String? userId,
  }) : _supervision = supervision,
       _modelKey = buildLlmModelKey(
         baseUrl: baseUrl,
         model: model,
         apiKey: apiKey,
       ),
       _purpose = purpose,
       _priority = priority,
       _weight = weight,
       _jobId = jobId,
       _userId = userId;

  void onStarted(String requestId) {
    final meta = LlmRequestMeta(
      id: requestId,
      purpose: _purpose,
      priority: _priority,
      weight: _weight,
      modelKey: _modelKey,
      jobId: _jobId,
      userId: _userId,
    );
    _requests[requestId] = _ExternalLlmRequestState(
      meta: meta,
      startedAt: DateTime.now(),
    );
    _supervision.onLlmEnqueued(meta);
    _supervision.onLlmStarted(meta);
  }

  void onFirstToken(String requestId, DateTime firstTokenAt) {
    final state = _requests[requestId];
    if (state == null) {
      return;
    }
    state.firstTokenAt ??= firstTokenAt;
    _supervision.onLlmFirstToken(state.meta, firstTokenAt);
  }

  void onTokenPerSecond(String requestId, double tps) {
    final state = _requests[requestId];
    if (state == null) {
      return;
    }
    state.tps = tps;
  }

  void onCompleted(String requestId, int totalTokens) {
    final state = _requests.remove(requestId);
    if (state == null) {
      return;
    }
    final doneAt = DateTime.now();
    final firstTokenAt = state.firstTokenAt;
    final ttft = firstTokenAt == null
        ? null
        : firstTokenAt.difference(state.startedAt);
    final metrics = LlmCallMetrics(
      meta: state.meta,
      startedAt: state.startedAt,
      firstTokenAt: firstTokenAt,
      doneAt: doneAt,
      totalTokens: totalTokens,
      ttft: ttft,
      tps: state.tps,
      success: true,
      error: null,
    );
    _supervision.onLlmCompleted(metrics);
  }

  void onFailed(String requestId, String error) {
    final state = _requests.remove(requestId);
    if (state == null) {
      return;
    }
    final doneAt = DateTime.now();
    final firstTokenAt = state.firstTokenAt;
    final ttft = firstTokenAt == null
        ? null
        : firstTokenAt.difference(state.startedAt);
    final metrics = LlmCallMetrics(
      meta: state.meta,
      startedAt: state.startedAt,
      firstTokenAt: firstTokenAt,
      doneAt: doneAt,
      totalTokens: null,
      ttft: ttft,
      tps: state.tps,
      success: false,
      error: error,
    );
    _supervision.onLlmCompleted(metrics);
  }
}

class LlmMetrics {
  final String requestId;
  final SupervisionLlmMetricsSink _sink;

  LlmMetrics(this.requestId, this._sink);

  void start() => _sink.onStarted(requestId);

  void setFirstToken(DateTime firstTokenAt) =>
      _sink.onFirstToken(requestId, firstTokenAt);

  void setTokenPerSecond(double tps) => _sink.onTokenPerSecond(requestId, tps);

  void completed(int totalTokens) => _sink.onCompleted(requestId, totalTokens);

  void failed(String error) => _sink.onFailed(requestId, error);
}

class _ExternalLlmRequestState {
  final LlmRequestMeta meta;
  final DateTime startedAt;
  DateTime? firstTokenAt;
  double? tps;

  _ExternalLlmRequestState({required this.meta, required this.startedAt});
}
