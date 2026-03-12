import 'dart:async';

import '../events.dart';
import '../logging/logger.dart';
import '../supervision/supervision.dart';
import 'model.dart';

typedef LlmWork<T> = Future<T> Function(LlmCallContext context);

class LlmQueue {
  final Supervision supervision;
  final KernelLogger? logger;

  final List<_LlmQueueItem<dynamic>> _pending = [];
  int _sequence = 0;
  int _inFlight = 0;
  final Map<String, int> _inFlightByModel = {};
  Timer? _retryTimer;

  LlmQueue({required this.supervision, this.logger});

  Future<T> enqueue<T>({
    required String purpose,
    required int priority,
    required int weight,
    required String modelKey,
    String? jobId,
    String? userId,
    required LlmWork<T> run,
  }) {
    final meta = LlmRequestMeta(
      id: _nextId(),
      purpose: purpose,
      priority: priority,
      weight: weight,
      modelKey: modelKey,
      jobId: jobId,
      userId: userId,
    );
    final completer = Completer<T>();
    final item = _LlmQueueItem<T>(meta: meta, run: run, completer: completer);
    _pending.add(item);
    supervision.onLlmEnqueued(meta);
    logger?.log(
      _LlmQueueEvent('LLM_QUEUED', meta, timestamp: meta.enqueuedAt),
      data: {
        'priority': priority,
        'weight': weight,
        'purpose': purpose,
        'modelKey': modelKey,
      },
    );
    _pump();
    return completer.future;
  }

  LlmQueueSnapshot snapshot() {
    return LlmQueueSnapshot(
      inFlight: _inFlight,
      queued: _pending.length,
      totalInFlight: _inFlight,
      totalQueued: _pending.length,
    );
  }

  LlmQueueSnapshot snapshotForModel(String modelKey) {
    final inFlightForModel = _inFlightByModel[modelKey] ?? 0;
    final queuedForModel = _pending
        .where((entry) => entry.meta.modelKey == modelKey)
        .length;
    return LlmQueueSnapshot(
      inFlight: inFlightForModel,
      queued: queuedForModel,
      totalInFlight: _inFlight,
      totalQueued: _pending.length,
    );
  }

  bool get isIdle => _inFlight == 0 && _pending.isEmpty;

  void _pump() {
    if (_pending.isEmpty) {
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    while (_pending.isNotEmpty) {
      final item = _pickNext();
      if (item == null) {
        _scheduleRetry();
        return;
      }
      _start(item);
    }
  }

  _LlmQueueItem<dynamic>? _pickNext() {
    if (_pending.isEmpty) {
      return null;
    }
    _pending.sort((a, b) {
      if (a.meta.priority != b.meta.priority) {
        return a.meta.priority.compareTo(b.meta.priority);
      }
      if (a.meta.weight != b.meta.weight) {
        return b.meta.weight.compareTo(a.meta.weight);
      }
      return a.order.compareTo(b.order);
    });
    for (var i = 0; i < _pending.length; i++) {
      final item = _pending[i];
      final modelKey = item.meta.modelKey;
      final snapshot = snapshotForModel(modelKey);
      final inFlightForModel = snapshot.inFlight;
      final maxConcurrency = supervision.recommendedLlmConcurrency(
        snapshot,
        modelKey,
      );
      if (inFlightForModel < maxConcurrency) {
        return _pending.removeAt(i);
      }
    }
    return null;
  }

  void _start(_LlmQueueItem<dynamic> item) {
    _inFlight += 1;
    _inFlightByModel[item.meta.modelKey] =
        (_inFlightByModel[item.meta.modelKey] ?? 0) + 1;
    final startedAt = DateTime.now();
    final context = LlmCallContext(
      meta: item.meta,
      onFirstToken: (firstTokenAt) {
        supervision.onLlmFirstToken(item.meta, firstTokenAt);
      },
    );
    supervision.onLlmStarted(item.meta);
    logger?.log(
      _LlmQueueEvent('LLM_STARTED', item.meta, timestamp: startedAt),
      data: {
        'purpose': item.meta.purpose,
        'priority': item.meta.priority,
        'modelKey': item.meta.modelKey,
      },
    );
    Future<void>(() async {
      try {
        final result = await item.run(context);
        final metrics = _buildMetrics(
          meta: item.meta,
          startedAt: startedAt,
          context: context,
          success: true,
          error: null,
        );
        supervision.onLlmCompleted(metrics);
        logger?.log(
          _LlmQueueEvent('LLM_DONE', item.meta, timestamp: metrics.doneAt),
          data: {
            'purpose': item.meta.purpose,
            'priority': item.meta.priority,
            'modelKey': item.meta.modelKey,
            'totalTokens': metrics.totalTokens,
            'ttftMs': metrics.ttft?.inMilliseconds,
          },
        );
        item.completer.complete(result);
      } catch (error) {
        final metrics = _buildMetrics(
          meta: item.meta,
          startedAt: startedAt,
          context: context,
          success: false,
          error: error.toString(),
        );
        supervision.onLlmCompleted(metrics);
        logger?.log(
          _LlmQueueEvent('LLM_FAILED', item.meta, timestamp: metrics.doneAt),
          data: {
            'purpose': item.meta.purpose,
            'priority': item.meta.priority,
            'modelKey': item.meta.modelKey,
            'error': metrics.error,
            'ttftMs': metrics.ttft?.inMilliseconds,
          },
        );
        item.completer.completeError(error);
      } finally {
        _inFlight -= 1;
        final modelKey = item.meta.modelKey;
        final current = _inFlightByModel[modelKey] ?? 1;
        if (current <= 1) {
          _inFlightByModel.remove(modelKey);
        } else {
          _inFlightByModel[modelKey] = current - 1;
        }
        _pump();
      }
    });
  }

  void _scheduleRetry() {
    if (_retryTimer != null) {
      return;
    }
    _retryTimer = Timer(const Duration(seconds: 1), () {
      _retryTimer = null;
      if (_pending.isNotEmpty) {
        _pump();
      }
    });
  }

  LlmCallMetrics _buildMetrics({
    required LlmRequestMeta meta,
    required DateTime startedAt,
    required LlmCallContext context,
    required bool success,
    required String? error,
  }) {
    final doneAt = DateTime.now();
    final firstTokenAt = context.firstTokenAt;
    final ttft = firstTokenAt == null
        ? null
        : firstTokenAt.difference(startedAt);
    double? tps;
    if (firstTokenAt != null && context.totalTokens != null) {
      final elapsed = doneAt.difference(firstTokenAt).inMilliseconds;
      if (elapsed > 0) {
        tps = context.totalTokens! / (elapsed / 1000.0);
      }
    }
    return LlmCallMetrics(
      meta: meta,
      startedAt: startedAt,
      firstTokenAt: firstTokenAt,
      doneAt: doneAt,
      totalTokens: context.totalTokens,
      contextUsageRatio: context.contextUsageRatio,
      ttft: ttft,
      tps: tps,
      success: success,
      error: error,
    );
  }

  String _nextId() {
    _sequence += 1;
    return 'llm-${DateTime.now().microsecondsSinceEpoch}-$_sequence';
  }
}

class _LlmQueueItem<T> {
  final LlmRequestMeta meta;
  final LlmWork<T> run;
  final Completer<T> completer;
  final int order;

  _LlmQueueItem({
    required this.meta,
    required this.run,
    required this.completer,
  }) : order = meta.enqueuedAt.microsecondsSinceEpoch;
}

class _LlmQueueEvent extends KernelEvent {
  _LlmQueueEvent(String type, LlmRequestMeta meta, {DateTime? timestamp})
    : super(
        type: type,
        jobId: meta.jobId ?? meta.id,
        userId: meta.userId,
        sessionId: null,
        source: 'llm_queue',
        timestamp: timestamp ?? meta.enqueuedAt,
      );
}
