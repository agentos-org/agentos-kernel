import 'dart:async';
import 'dart:collection';

import '../logging/logger.dart';
import '../supervision/supervision.dart';
import 'tool_call_store.dart';

enum ToolCallQueueOverflowStrategy {
  dropOldest,
  dropNewest,
}

class QueuedToolCallStore implements ToolCallStore {
  final ToolCallStore delegate;
  final Supervision supervision;
  final KernelLogger? logger;
  final int batchSize;
  final Duration flushInterval;
  final Duration maxBackoff;
  final int maxQueueSize;
  final ToolCallQueueOverflowStrategy overflowStrategy;

  final Queue<ToolCallRecord> _queue = Queue<ToolCallRecord>();
  bool _flushing = false;
  Duration _backoff = Duration.zero;
  Timer? _timer;

  QueuedToolCallStore({
    required this.delegate,
    required this.supervision,
    this.logger,
    this.batchSize = 50,
    this.flushInterval = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 5),
    this.maxQueueSize = 10000,
    this.overflowStrategy = ToolCallQueueOverflowStrategy.dropOldest,
  });

  @override
  Future<void> record(ToolCallRecord record) async {
    if (_queue.length >= maxQueueSize) {
      _handleOverflow(record);
    } else {
      _queue.addLast(record);
    }
    _ensureScheduled();
  }

  void _handleOverflow(ToolCallRecord incoming) {
    if (overflowStrategy == ToolCallQueueOverflowStrategy.dropOldest) {
      if (_queue.isNotEmpty) {
        _queue.removeFirst();
      }
      _queue.addLast(incoming);
      logger?.warn(
        'Tool call queue full. Dropped oldest record.',
        data: {'maxQueueSize': maxQueueSize},
      );
    } else {
      logger?.warn(
        'Tool call queue full. Dropped newest record.',
        data: {'maxQueueSize': maxQueueSize},
      );
    }
  }

  void _ensureScheduled() {
    if (_timer != null) {
      return;
    }
    final delay = _backoff > Duration.zero ? _backoff : flushInterval;
    _timer = Timer(delay, _flush);
  }

  void _scheduleBackoff() {
    final next = _nextBackoff();
    _backoff = next;
    _timer?.cancel();
    _timer = Timer(next, _flush);
  }

  Duration _nextBackoff() {
    if (_backoff == Duration.zero) {
      return flushInterval;
    }
    final doubled = Duration(milliseconds: _backoff.inMilliseconds * 2);
    if (doubled > maxBackoff) {
      return maxBackoff;
    }
    return doubled;
  }

  Future<void> _flush() async {
    _timer = null;
    if (_flushing || _queue.isEmpty) {
      return;
    }
    if (supervision.isSystemBusy()) {
      _scheduleBackoff();
      return;
    }
    _flushing = true;
    final batch = <ToolCallRecord>[];
    while (batch.length < batchSize && _queue.isNotEmpty) {
      batch.add(_queue.removeFirst());
    }
    try {
      for (final record in batch) {
        await delegate.record(record);
      }
      _backoff = Duration.zero;
    } catch (error) {
      for (var i = batch.length - 1; i >= 0; i--) {
        _queue.addFirst(batch[i]);
      }
      logger?.error('Failed to flush tool call records.', error);
      _scheduleBackoff();
      _flushing = false;
      return;
    }
    _flushing = false;
    if (_queue.isNotEmpty) {
      _ensureScheduled();
    }
  }
}
