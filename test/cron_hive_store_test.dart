import 'dart:io';

import 'package:agentos_kernel/src/kernel/cron/model.dart';
import 'package:agentos_kernel/src/kernel/cron/store.dart';
import 'package:hive/hive.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  group('HiveCronTaskStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cron_store_test');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await Hive.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('persists tasks runs and messages across reopen', () async {
      final firstStore = HiveCronTaskStore(
        taskBox: await Hive.openBox<Map>('cron_tasks'),
        runBox: await Hive.openBox<Map>('cron_runs'),
        messageBox: await Hive.openBox<Map>('cron_messages'),
      );
      final task = CronTaskDefinition(
        cronId: 'cron-1',
        name: 'nightly-report',
        schedule: '*/5 * * * *',
        source: 'api',
        concurrency: CronTaskConcurrencyPolicy.skipIfRunning,
        spec: AgentCronSpec(
          systemPrompt: 'You are a cron agent.',
          content: [
            Content(
              type: ContentType.text,
              message: 'Generate the nightly report.',
            ),
          ],
          llmConfig: LLMConfig(
            baseUrl: 'https://api.example.com/v1',
            apiKey: 'task-key',
            model: 'external-model',
            contextWindowSize: 64000,
          ),
        ),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        lastRunAt: DateTime(2026, 1, 2),
        status: CronTaskStatus.active,
      );
      final run = CronRunRecord(
        runId: 'run-1',
        cronId: task.cronId,
        trigger: CronRunTrigger.manual,
        scheduledAt: DateTime(2026, 1, 2),
        startedAt: DateTime(2026, 1, 2),
        finishedAt: DateTime(2026, 1, 2, 0, 1),
        status: CronRunStatus.succeeded,
        llmConfig: LLMConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'run-key',
          model: 'run-model',
          contextWindowSize: 32000,
        ),
        result: const {'content': 'done'},
        displayMessageId: 'msg-1',
        displayText: 'done',
      );
      final message = CronRunMessageRecord(
        messageId: 'msg-1',
        runId: run.runId,
        cronId: task.cronId,
        timestamp: DateTime(2026, 1, 2),
        message: AgentMessage(
          sessionId: 'session-1',
          taskId: 'task-1',
          role: AgentRoleType.LLM,
          to: AgentRoleType.USER,
          type: AgentMessageType.TEXT,
          content: 'done',
          reasoningContent: 'thinking',
          createTime: DateTime(2026, 1, 2),
        ),
      );

      await firstStore.putTask(task);
      await firstStore.putRun(run);
      await firstStore.putRunMessage(message);
      await Hive.close();

      Hive.init(tempDir.path);
      final secondStore = HiveCronTaskStore(
        taskBox: await Hive.openBox<Map>('cron_tasks'),
        runBox: await Hive.openBox<Map>('cron_runs'),
        messageBox: await Hive.openBox<Map>('cron_messages'),
      );

      final loadedTask = await secondStore.getTask(task.cronId);
      final loadedRun = await secondStore.getRun(run.runId);
      final loadedMessages = await secondStore.listRunMessages(run.runId);

      expect(loadedTask, isNotNull);
      expect(loadedTask!.name, task.name);
      expect(loadedTask.enabled, isTrue);
      expect(loadedTask.spec.llmConfig, isNotNull);
      expect(loadedTask.spec.llmConfig!.baseUrl, 'https://api.example.com/v1');
      expect(loadedTask.spec.llmConfig!.model, 'external-model');
      expect(loadedTask.spec.llmConfig!.contextWindowSize, 64000);
      expect(loadedRun, isNotNull);
      expect(loadedRun!.trigger, CronRunTrigger.manual);
      expect(loadedRun.llmConfig, isNotNull);
      expect(loadedRun.llmConfig!.model, 'run-model');
      expect(loadedRun.llmConfig!.contextWindowSize, 32000);
      expect(loadedRun.hasDisplayableResult, isTrue);
      expect(loadedRun.displayText, 'done');
      expect(loadedMessages, hasLength(1));
      expect(loadedMessages.first.message.content, 'done');
      expect(loadedMessages.first.message.reasoningContent, 'thinking');
    });

    test(
      'reads nested task status message content after Hive reopen',
      () async {
        final firstStore = HiveCronTaskStore(
          taskBox: await Hive.openBox<Map>('cron_tasks'),
          runBox: await Hive.openBox<Map>('cron_runs'),
          messageBox: await Hive.openBox<Map>('cron_messages'),
        );
        final message = CronRunMessageRecord(
          messageId: 'msg-nested-1',
          runId: 'run-nested-1',
          cronId: 'cron-nested-1',
          timestamp: DateTime(2026, 1, 3),
          message: AgentMessage(
            sessionId: 'session-1',
            taskId: 'task-1',
            role: AgentRoleType.LLM,
            to: AgentRoleType.USER,
            type: AgentMessageType.TASK_STATUS,
            content: {'status': 'done', 'taskId': '2033816948801933312'},
            createTime: DateTime(2026, 1, 3),
          ),
        );

        await firstStore.putRunMessage(message);
        await Hive.close();

        Hive.init(tempDir.path);
        final secondStore = HiveCronTaskStore(
          taskBox: await Hive.openBox<Map>('cron_tasks'),
          runBox: await Hive.openBox<Map>('cron_runs'),
          messageBox: await Hive.openBox<Map>('cron_messages'),
        );

        final loadedMessages = await secondStore.listRunMessages(message.runId);

        expect(loadedMessages, hasLength(1));
        final loadedContent = loadedMessages.first.message.content;
        expect(loadedContent, isA<Map<String, dynamic>>());
        final loadedMap = loadedContent as Map<String, dynamic>;
        expect(loadedMap['status'], 'done');
        expect(loadedMap['taskId'], '2033816948801933312');
      },
    );

    test('deletes a persisted run and cascades its messages', () async {
      final store = HiveCronTaskStore(
        taskBox: await Hive.openBox<Map>('cron_tasks'),
        runBox: await Hive.openBox<Map>('cron_runs'),
        messageBox: await Hive.openBox<Map>('cron_messages'),
      );
      final run = CronRunRecord(
        runId: 'run-delete-1',
        cronId: 'cron-delete-1',
        trigger: CronRunTrigger.schedule,
        scheduledAt: DateTime(2026, 1, 4),
        startedAt: DateTime(2026, 1, 4),
        status: CronRunStatus.succeeded,
      );
      final message = CronRunMessageRecord(
        messageId: 'msg-delete-1',
        runId: run.runId,
        cronId: 'cron-delete-1',
        timestamp: DateTime(2026, 1, 4),
        message: AgentMessage(
          sessionId: 'session-1',
          taskId: 'task-1',
          role: AgentRoleType.LLM,
          to: AgentRoleType.USER,
          type: AgentMessageType.TEXT,
          content: 'done',
          createTime: DateTime(2026, 1, 4),
        ),
      );

      await store.putRun(run);
      await store.putRunMessage(message);
      expect(await store.getRun(run.runId), isNotNull);
      expect(await store.listRunMessages(message.runId), hasLength(1));

      await store.deleteRun(run.runId);

      expect(await store.getRun(run.runId), isNull);
      expect(await store.listRunMessages(message.runId), isEmpty);
    });
  });
}
