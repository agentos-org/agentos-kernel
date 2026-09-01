import 'dart:async';

import 'model.dart';
import 'timezone.dart';

typedef CronTaskTrigger =
    Future<void> Function(CronTaskDefinition task, {DateTime? scheduledAt});

/// Schedules each task against its own wall-clock timezone.
class CronScheduler {
  static const Duration _maxTimerDelay = Duration(days: 1);

  final CronTaskTrigger onTrigger;
  final Map<String, _ScheduledCronTask> _scheduled = {};
  DateTime? _lastTickAt;
  bool _running = false;

  CronScheduler({required this.onTrigger});

  bool get isRunning => _running;

  DateTime? get lastTickAt => _lastTickAt;

  Future<void> start(List<CronTaskDefinition> tasks) async {
    if (_running) {
      await refresh(tasks);
      return;
    }
    _running = true;
    await refresh(tasks);
  }

  Future<void> stop() async {
    _running = false;
    for (final task in _scheduled.values) {
      task.cancel();
    }
    _scheduled.clear();
  }

  Future<void> refresh(List<CronTaskDefinition> tasks) async {
    for (final task in _scheduled.values) {
      task.cancel();
    }
    _scheduled.clear();
    if (!_running) {
      return;
    }
    for (final task in tasks) {
      if (!task.enabled) {
        continue;
      }
      final scheduled = _ScheduledCronTask(task);
      _scheduled[task.cronId] = scheduled;
      _arm(scheduled);
    }
  }

  void _arm(_ScheduledCronTask scheduled) {
    if (!_isCurrent(scheduled)) {
      return;
    }
    final now = DateTime.now().toUtc();
    final nextRunAt = CronScheduleCalculator.nextRunAt(
      schedule: scheduled.task.schedule,
      timezoneName: scheduled.task.timezone,
      after: now,
    );
    scheduled.nextRunAt = nextRunAt;
    if (nextRunAt == null) {
      return;
    }

    final delay = nextRunAt.difference(now);
    if (delay <= Duration.zero) {
      scheduled.timer = Timer(Duration.zero, () => _fire(scheduled));
      return;
    }
    final timerDelay = delay > _maxTimerDelay ? _maxTimerDelay : delay;
    scheduled.timer = Timer(timerDelay, () {
      if (!_isCurrent(scheduled)) {
        return;
      }
      if (delay > _maxTimerDelay) {
        _arm(scheduled);
      } else {
        _fire(scheduled);
      }
    });
  }

  Future<void> _fire(_ScheduledCronTask scheduled) async {
    if (!_isCurrent(scheduled)) {
      return;
    }
    final nextRunAt = scheduled.nextRunAt;
    if (nextRunAt == null) {
      return;
    }
    _lastTickAt = DateTime.now().toUtc();
    try {
      await onTrigger(scheduled.task, scheduledAt: nextRunAt);
    } catch (_) {
      // The module persists execution failures. A timer callback must not
      // surface an unhandled asynchronous error and stop scheduling siblings.
    } finally {
      if (_isCurrent(scheduled)) {
        _arm(scheduled);
      }
    }
  }

  bool _isCurrent(_ScheduledCronTask scheduled) {
    return _running &&
        !scheduled.cancelled &&
        identical(_scheduled[scheduled.task.cronId], scheduled);
  }
}

class _ScheduledCronTask {
  final CronTaskDefinition task;
  Timer? timer;
  DateTime? nextRunAt;
  bool cancelled = false;

  _ScheduledCronTask(this.task);

  void cancel() {
    cancelled = true;
    timer?.cancel();
    timer = null;
  }
}
