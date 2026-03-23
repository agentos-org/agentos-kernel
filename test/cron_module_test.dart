import 'dart:async';

import 'package:agentos_kernel/src/kernel/cron/executor.dart';
import 'package:agentos_kernel/src/kernel/cron/model.dart';
import 'package:agentos_kernel/src/kernel/cron/module.dart';
import 'package:agentos_kernel/src/kernel/cron/store.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  group('CronModule', () {
    test('creates task and executes it immediately', () async {
      final module = CronModule(
        store: InMemoryCronTaskStore(),
        executor: _FakeCronExecutor(),
      );

      final task = await module.createTask(
        name: 'nightly-sync',
        schedule: '*/5 * * * *',
        source: 'api',
        spec: AgentCronSpec(
          systemPrompt: 'You are an auto agent.',
          content: [Content(type: ContentType.text, message: 'sync records')],
        ),
      );

      final tasks = await module.listTasks();
      final run = await module.runTaskNow(task.cronId);
      final loadedRun = await module.getRun(run.runId);
      final messages = await module.listRunMessages(run.runId);

      expect(tasks, hasLength(1));
      expect(tasks.first.cronId, task.cronId);
      expect(run.cronId, task.cronId);
      expect(run.trigger, CronRunTrigger.manual);
      expect(run.status, CronRunStatus.succeeded);
      expect(run.hasDisplayableResult, isTrue);
      expect(run.displayText, 'sync records');
      expect(run.result?['content'], 'sync records');
      expect(loadedRun, isNotNull);
      expect(loadedRun!.runId, run.runId);
      expect(loadedRun.hasDisplayableResult, isTrue);
      expect(messages, hasLength(1));
      expect(messages.first.cronId, task.cronId);
      expect(messages.first.message.content, 'sync records');
    });

    test('does not mark failed run as displayable result', () async {
      final module = CronModule(
        store: InMemoryCronTaskStore(),
        executor: _FailingCronExecutor(),
      );

      final task = await module.createTask(
        name: 'nightly-sync',
        schedule: '*/5 * * * *',
        source: 'api',
        spec: AgentCronSpec(
          systemPrompt: 'You are an auto agent.',
          content: [Content(type: ContentType.text, message: 'sync records')],
        ),
      );

      final run = await module.runTaskNow(task.cronId);

      expect(run.status, CronRunStatus.failed);
      expect(run.hasDisplayableResult, isFalse);
      expect(run.displayText, isNull);
    });

    test(
      'marks skipped concurrent run as cancelled and not displayable',
      () async {
        final executor = _BlockingCronExecutor();
        final module = CronModule(
          store: InMemoryCronTaskStore(),
          executor: executor,
        );

        final task = await module.createTask(
          name: 'nightly-sync',
          schedule: '*/5 * * * *',
          source: 'api',
          spec: AgentCronSpec(
            systemPrompt: 'You are an auto agent.',
            content: [Content(type: ContentType.text, message: 'sync records')],
          ),
        );

        final firstRunFuture = module.runTaskNow(task.cronId);
        await executor.started.future;
        final skipped = await module.runTaskNow(task.cronId);
        executor.complete();
        final firstRun = await firstRunFuture;

        expect(skipped.status, CronRunStatus.cancelled);
        expect(skipped.hasDisplayableResult, isFalse);
        expect(skipped.displayText, isNull);
        expect(firstRun.status, CronRunStatus.succeeded);
        expect(firstRun.hasDisplayableResult, isTrue);
      },
    );

    test('stores messages while run is still in progress', () async {
      final executor = _StreamingCronExecutor();
      final module = CronModule(
        store: InMemoryCronTaskStore(),
        executor: executor,
      );

      final task = await module.createTask(
        name: 'nightly-sync',
        schedule: '*/5 * * * *',
        source: 'api',
        spec: AgentCronSpec(
          systemPrompt: 'You are an auto agent.',
          content: [Content(type: ContentType.text, message: 'sync records')],
        ),
      );

      final runFuture = module.runTaskNow(task.cronId);
      await executor.messageStored.future;
      final runs = await module.listRuns(cronId: task.cronId);
      final runningRun = runs.single;
      final messages = await module.listRunMessages(runningRun.runId);

      expect(runningRun.status, CronRunStatus.running);
      expect(messages, hasLength(1));
      expect(messages.first.message.content, 'partial sync');

      executor.complete();
      final finished = await runFuture;
      expect(runningRun.trigger, CronRunTrigger.manual);
      expect(finished.status, CronRunStatus.succeeded);
      expect(finished.hasDisplayableResult, isTrue);
    });

    test('scheduler-triggered run is marked as schedule trigger', () async {
      final module = CronModule(
        store: InMemoryCronTaskStore(),
        executor: _FakeCronExecutor(),
      );

      final task = await module.createTask(
        name: 'nightly-sync',
        schedule: '*/5 * * * *',
        source: 'api',
        spec: AgentCronSpec(
          systemPrompt: 'You are an auto agent.',
          content: [Content(type: ContentType.text, message: 'sync records')],
        ),
      );

      final run = await module.runNow(task, scheduledAt: DateTime(2026, 1, 1));

      expect(run.trigger, CronRunTrigger.schedule);
    });

    test(
      'historical run keeps its original llm model after task update',
      () async {
        final module = CronModule(
          store: InMemoryCronTaskStore(),
          executor: _EchoLlmConfigCronExecutor(),
        );

        final task = await module.createTask(
          name: 'nightly-sync',
          schedule: '*/5 * * * *',
          source: 'api',
          spec: AgentCronSpec(
            systemPrompt: 'You are an auto agent.',
            content: [Content(type: ContentType.text, message: 'sync records')],
            llmConfig: LLMConfig(
              baseUrl: 'https://api.example.com/v1',
              apiKey: 'task-key-a',
              model: 'model-a',
              contextWindowSize: 32000,
            ),
          ),
        );

        final run = await module.runTaskNow(task.cronId);

        await module.updateTask(
          cronId: task.cronId,
          spec: AgentCronSpec(
            systemPrompt: task.spec.systemPrompt,
            content: task.spec.content,
            llmConfig: LLMConfig(
              baseUrl: 'https://api.example.com/v1',
              apiKey: 'task-key-b',
              model: 'model-b',
              contextWindowSize: 64000,
            ),
          ),
        );

        final loadedRun = await module.getRun(run.runId);
        final runs = await module.listRuns(cronId: task.cronId);
        final updatedTask = await module.getTask(task.cronId);

        expect(updatedTask, isNotNull);
        expect(updatedTask!.spec.llmConfig!.model, 'model-b');
        expect(loadedRun, isNotNull);
        expect(loadedRun!.llmConfig, isNotNull);
        expect(loadedRun.llmConfig!.model, 'model-a');
        expect(runs.single.llmConfig!.model, 'model-a');
      },
    );

    test('deletes a stored run and cascades its messages', () async {
      final module = CronModule(
        store: InMemoryCronTaskStore(),
        executor: _FakeCronExecutor(),
      );

      final task = await module.createTask(
        name: 'nightly-sync',
        schedule: '*/5 * * * *',
        source: 'api',
        spec: AgentCronSpec(
          systemPrompt: 'You are an auto agent.',
          content: [Content(type: ContentType.text, message: 'sync records')],
        ),
      );

      final run = await module.runTaskNow(task.cronId);
      final messagesBefore = await module.listRunMessages(run.runId);

      expect(messagesBefore, hasLength(1));

      await module.deleteRun(run.runId);

      final loadedRun = await module.getRun(run.runId);
      final messagesAfter = await module.listRunMessages(run.runId);
      expect(loadedRun, isNull);
      expect(messagesAfter, isEmpty);
    });
  });
}

class _FakeCronExecutor implements CronTaskExecutor {
  @override
  Future<CronExecutionResult> run(
    CronTaskDefinition task, {
    Future<void> Function(AgentMessage message)? onMessage,
  }) async {
    return CronExecutionResult(
      liteAgentSessionId: 'session-1',
      result: {'content': 'sync records'},
      displayMessageId: 'liteagent-task-1',
      displayText: 'sync records',
      messages: [
        AgentMessage(
          sessionId: 'session-1',
          taskId: 'liteagent-task-1',
          role: AgentRoleType.LLM,
          to: AgentRoleType.USER,
          type: AgentMessageType.TEXT,
          content: 'sync records',
          createTime: DateTime(2026, 1, 1),
        ),
      ],
    );
  }
}

class _FailingCronExecutor implements CronTaskExecutor {
  @override
  Future<CronExecutionResult> run(
    CronTaskDefinition task, {
    Future<void> Function(AgentMessage message)? onMessage,
  }) async {
    return const CronExecutionResult(error: 'upstream failed');
  }
}

class _EchoLlmConfigCronExecutor implements CronTaskExecutor {
  @override
  Future<CronExecutionResult> run(
    CronTaskDefinition task, {
    Future<void> Function(AgentMessage message)? onMessage,
  }) async {
    return CronExecutionResult(
      llmConfig: task.spec.llmConfig,
      liteAgentSessionId: 'session-1',
      result: {'content': 'sync records'},
      displayMessageId: 'liteagent-task-1',
      displayText: 'sync records',
      messages: [
        AgentMessage(
          sessionId: 'session-1',
          taskId: 'liteagent-task-1',
          role: AgentRoleType.LLM,
          to: AgentRoleType.USER,
          type: AgentMessageType.TEXT,
          content: 'sync records',
          createTime: DateTime(2026, 1, 1),
        ),
      ],
    );
  }
}

class _BlockingCronExecutor implements CronTaskExecutor {
  final Completer<void> started = Completer<void>();
  final Completer<void> _done = Completer<void>();

  void complete() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<CronExecutionResult> run(
    CronTaskDefinition task, {
    Future<void> Function(AgentMessage message)? onMessage,
  }) async {
    if (!started.isCompleted) {
      started.complete();
    }
    await _done.future;
    return CronExecutionResult(
      liteAgentSessionId: 'session-1',
      result: {'content': 'sync records'},
      displayMessageId: 'liteagent-task-1',
      displayText: 'sync records',
      messages: [
        AgentMessage(
          sessionId: 'session-1',
          taskId: 'liteagent-task-1',
          role: AgentRoleType.LLM,
          to: AgentRoleType.USER,
          type: AgentMessageType.TEXT,
          content: 'sync records',
          createTime: DateTime(2026, 1, 1),
        ),
      ],
    );
  }
}

class _StreamingCronExecutor implements CronTaskExecutor {
  final Completer<void> messageStored = Completer<void>();
  final Completer<void> _done = Completer<void>();

  void complete() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<CronExecutionResult> run(
    CronTaskDefinition task, {
    Future<void> Function(AgentMessage message)? onMessage,
  }) async {
    final partial = AgentMessage(
      sessionId: 'session-1',
      taskId: 'liteagent-task-1',
      role: AgentRoleType.LLM,
      to: AgentRoleType.USER,
      type: AgentMessageType.TEXT,
      content: 'partial sync',
      createTime: DateTime(2026, 1, 1, 0, 0, 1),
    );
    await onMessage?.call(partial);
    if (!messageStored.isCompleted) {
      messageStored.complete();
    }
    await _done.future;
    return CronExecutionResult(
      liteAgentSessionId: 'session-1',
      result: {'content': 'sync records'},
      displayMessageId: 'liteagent-task-1',
      displayText: 'sync records',
      messages: [
        partial,
        AgentMessage(
          sessionId: 'session-1',
          taskId: 'liteagent-task-1',
          role: AgentRoleType.LLM,
          to: AgentRoleType.USER,
          type: AgentMessageType.TEXT,
          content: 'sync records',
          createTime: DateTime(2026, 1, 1, 0, 0, 2),
        ),
      ],
    );
  }
}
