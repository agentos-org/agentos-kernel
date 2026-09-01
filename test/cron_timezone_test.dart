import 'package:agentos_kernel/src/kernel/cron/executor.dart';
import 'package:agentos_kernel/src/kernel/cron/model.dart';
import 'package:agentos_kernel/src/kernel/cron/module.dart';
import 'package:agentos_kernel/src/kernel/cron/store.dart';
import 'package:agentos_kernel/src/kernel/cron/timezone.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  group('CronScheduleCalculator', () {
    test('converts the same local cron time to each timezone', () {
      final after = DateTime.utc(2026, 1, 1);

      expect(
        CronScheduleCalculator.nextRunAt(
          schedule: '0 9 * * *',
          timezoneName: 'Asia/Shanghai',
          after: after,
        ),
        DateTime.utc(2026, 1, 1, 1),
      );
      expect(
        CronScheduleCalculator.nextRunAt(
          schedule: '0 9 * * *',
          timezoneName: 'America/New_York',
          after: after,
        ),
        DateTime.utc(2026, 1, 1, 14),
      );
    });

    test('rejects an invalid IANA timezone', () {
      expect(
        () => CronScheduleCalculator.nextRunAt(
          schedule: '0 9 * * *',
          timezoneName: 'Mars/Olympus',
          after: DateTime.utc(2026, 1, 1),
        ),
        throwsA(isA<CronTimezoneException>()),
      );
    });

    test('skips a local time in the spring DST gap', () {
      final skipped = CronTimeZone.localWallToUtc(
        DateTime.utc(2026, 3, 8, 2, 30),
        timezoneName: 'America/New_York',
      );
      final next = CronScheduleCalculator.nextRunAt(
        schedule: '30 2 * * *',
        timezoneName: 'America/New_York',
        after: DateTime.utc(2026, 3, 8),
      );

      expect(skipped, isNull);
      expect(next, DateTime.utc(2026, 3, 9, 6, 30));
    });

    test('runs an autumn repeated local time only once', () {
      final first = CronScheduleCalculator.nextRunAt(
        schedule: '30 1 * * *',
        timezoneName: 'America/New_York',
        after: DateTime.utc(2026, 11, 1),
      );
      final afterFirstOccurrence = CronScheduleCalculator.nextRunAt(
        schedule: '30 1 * * *',
        timezoneName: 'America/New_York',
        after: DateTime.utc(2026, 11, 1, 5, 45),
      );

      expect(first, DateTime.utc(2026, 11, 1, 5, 30));
      expect(afterFirstOccurrence, DateTime.utc(2026, 11, 2, 6, 30));
    });
  });

  group('CronModule timezone lifecycle', () {
    test('validates timezone and recalculates nextRunAt on updates', () async {
      final module = CronModule(
        store: InMemoryCronTaskStore(),
        executor: _NoopCronExecutor(),
      );
      final task = await module.createTask(
        name: 'morning-report',
        schedule: '0 9 * * *',
        source: 'test',
        timezone: 'Asia/Shanghai',
        spec: _spec(),
      );

      expect(task.nextRunAt, isNotNull);
      expect(task.nextRunAt!.isUtc, isTrue);
      expect(
        CronTimeZone.toTaskLocal(
          task.nextRunAt!,
          timezoneName: task.timezone,
        ).hour,
        9,
      );

      final updated = await module.updateTask(
        cronId: task.cronId,
        timezone: 'America/New_York',
      );

      expect(updated.nextRunAt, isNotNull);
      expect(updated.nextRunAt!.isUtc, isTrue);
      expect(
        CronTimeZone.toTaskLocal(
          updated.nextRunAt!,
          timezoneName: updated.timezone,
        ).hour,
        9,
      );
    });

    test('rejects an invalid timezone on create and update', () async {
      final module = CronModule(
        store: InMemoryCronTaskStore(),
        executor: _NoopCronExecutor(),
      );

      await expectLater(
        module.createTask(
          name: 'invalid-create',
          schedule: '0 9 * * *',
          source: 'test',
          timezone: 'Mars/Olympus',
          enabled: false,
          spec: _spec(),
        ),
        throwsA(isA<CronTimezoneException>()),
      );

      final task = await module.createTask(
        name: 'valid-task',
        schedule: '0 9 * * *',
        source: 'test',
        timezone: 'UTC',
        enabled: false,
        spec: _spec(),
      );
      await expectLater(
        module.updateTask(cronId: task.cronId, timezone: 'Mars/Olympus'),
        throwsA(isA<CronTimezoneException>()),
      );
    });

    test('updates nextRunAt after execution using UTC instants', () async {
      final module = CronModule(
        store: InMemoryCronTaskStore(),
        executor: _NoopCronExecutor(),
      );
      final task = await module.createTask(
        name: 'scheduled-report',
        schedule: '0 9 * * *',
        source: 'test',
        timezone: 'Asia/Shanghai',
        spec: _spec(),
      );

      final run = await module.runTaskNow(
        task.cronId,
        scheduledAt: DateTime.utc(2026, 9, 1, 1),
      );
      final updated = await module.getTask(task.cronId);

      expect(run.status, CronRunStatus.succeeded);
      expect(run.scheduledAt.isUtc, isTrue);
      expect(updated, isNotNull);
      expect(updated!.lastRunAt, isNotNull);
      expect(updated.lastRunAt!.isUtc, isTrue);
      expect(updated.nextRunAt, isNotNull);
      expect(updated.nextRunAt!.isUtc, isTrue);
      final nextLocal = CronTimeZone.toTaskLocal(
        updated.nextRunAt!,
        timezoneName: updated.timezone,
      );
      expect(nextLocal.hour, 9);
      expect(nextLocal.minute, 0);
    });
  });
}

AgentCronSpec _spec() {
  return const AgentCronSpec(
    systemPrompt: 'You are a cron agent.',
    content: [],
  );
}

class _NoopCronExecutor implements CronTaskExecutor {
  @override
  Future<CronExecutionResult> run(
    CronTaskDefinition task, {
    DateTime? scheduledAt,
    Future<void> Function(AgentMessage message)? onMessage,
  }) async {
    return const CronExecutionResult();
  }
}
