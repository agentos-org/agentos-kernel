import 'dart:async';

import 'package:cron/cron.dart';

import 'model.dart';

typedef CronTaskTrigger =
    Future<void> Function(CronTaskDefinition task, {DateTime? scheduledAt});

class CronScheduler {
  Cron? _cron;
  final CronTaskTrigger onTrigger;
  final Map<String, ScheduledTask> _scheduled = {};
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
    _cron = Cron();
    _running = true;
    await refresh(tasks);
  }

  Future<void> stop() async {
    _running = false;
    for (final task in _scheduled.values) {
      task.cancel();
    }
    _scheduled.clear();
    await _cron?.close();
    _cron = null;
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
      final schedule = Schedule.parse(task.schedule);
      final cron = _cron;
      if (cron == null) {
        return;
      }
      _scheduled[task.cronId] = cron.schedule(schedule, () async {
        _lastTickAt = DateTime.now();
        await onTrigger(task, scheduledAt: _lastTickAt);
      });
    }
  }
}
