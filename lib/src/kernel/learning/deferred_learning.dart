import 'dart:async';

import '../agent/llm_queue.dart';
import '../logging/logger.dart';
import 'learning.dart';
import 'model.dart';

class DeferredLearning implements Learning {
  final Learning _delegate;
  final LlmQueue _llmQueue;
  final KernelLogger? _logger;
  final Duration _interval;
  final int _maxPerRun;
  final int _queueLimit;
  final bool _enabled;
  final List<LearningRecord> _queue = [];
  Timer? _timer;
  bool _running = false;

  DeferredLearning({
    required Learning delegate,
    required LlmQueue llmQueue,
    KernelLogger? logger,
    Duration interval = const Duration(minutes: 5),
    int maxPerRun = 1,
    int queueLimit = 500,
    bool enabled = true,
  })  : _delegate = delegate,
        _llmQueue = llmQueue,
        _logger = logger,
        _interval = interval,
        _maxPerRun = maxPerRun,
        _queueLimit = queueLimit,
        _enabled = enabled {
    if (_enabled) {
      _start();
    }
  }

  @override
  Future<void> consume(LearningRecord record) async {
    if (!_enabled) {
      return _delegate.consume(record);
    }
    _queue.add(record);
    if (_queueLimit > 0 && _queue.length > _queueLimit) {
      _queue.removeAt(0);
    }
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => unawaited(_drain()));
  }

  Future<void> _drain() async {
    if (_running || _queue.isEmpty) {
      return;
    }
    if (!_llmQueue.isIdle) {
      return;
    }
    _running = true;
    try {
      final maxRuns = _maxPerRun <= 0 ? 1 : _maxPerRun;
      for (var i = 0; i < maxRuns && _queue.isNotEmpty; i += 1) {
        if (!_llmQueue.isIdle) {
          break;
        }
        final record = _queue.removeAt(0);
        await _delegate.consume(record);
      }
    } catch (error) {
      _logger?.error('Deferred learning failed.', error);
    } finally {
      _running = false;
    }
  }
}
