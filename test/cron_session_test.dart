import 'dart:async';

import 'package:agentos_kernel/src/kernel/cron/agent_executor.dart';
import 'package:agentos_kernel/src/kernel/cron/executor.dart';
import 'package:agentos_kernel/src/kernel/cron/model.dart';
import 'package:agentos_kernel/src/kernel/cron/module.dart';
import 'package:agentos_kernel/src/kernel/cron/store.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  group('AgentCronExecutor sessionId', () {
    test('initializes a session when sessionId is empty', () async {
      final sdk = _RecordingSessionSdk(initSessionId: 'created-session');
      final executor = AgentCronExecutor(
        sdk: sdk,
        llmConfigResolver: () =>
            LLMConfig(baseUrl: 'http://127.0.0.1:9000', model: 'test-model'),
      );

      final result = await executor.run(_task(sessionId: '  '));

      expect(result.success, isTrue);
      expect(sdk.initSessionCalls, 1);
      expect(sdk.chatSessionIds, ['created-session']);
    });

    test(
      'reuses a non-empty sessionId without initializing a session',
      () async {
        final sdk = _RecordingSessionSdk(initSessionId: 'should-not-be-used');
        var llmConfigResolverCalls = 0;
        final executor = AgentCronExecutor(
          sdk: sdk,
          llmConfigResolver: () {
            llmConfigResolverCalls += 1;
            throw StateError(
              'must not resolve LLM config for a reused session',
            );
          },
        );

        final result = await executor.run(
          _task(sessionId: '  existing-session  ', timezone: 'Asia/Shanghai'),
          scheduledAt: DateTime.utc(2026, 9, 1, 1),
        );

        expect(result.success, isTrue);
        expect(result.liteAgentSessionId, 'existing-session');
        expect(result.llmConfig, isNull);
        expect(sdk.initSessionCalls, 0);
        expect(sdk.chatSessionIds, ['existing-session']);
        expect(llmConfigResolverCalls, 0);
        expect(
          sdk.userTasks.single.content.single.message,
          'Run the cron task.\n'
          '*Current Time: 2026-09-01 09:00:00 (Asia/Shanghai)*',
        );
      },
    );

    test('fails explicitly when a reused session does not exist', () async {
      final sdk = _RecordingSessionSdk(
        initSessionId: 'unused',
        chatError: StateError('session not found'),
      );
      final executor = AgentCronExecutor(sdk: sdk);

      final result = await executor.run(_task(sessionId: 'missing-session'));

      expect(result.success, isFalse);
      expect(
        result.error,
        contains('Cron session "missing-session" is unavailable'),
      );
      expect(sdk.initSessionCalls, 0);
      expect(sdk.chatSessionIds, ['missing-session']);
    });

    test(
      'fails explicitly when history for a reused session has expired',
      () async {
        final sdk = _RecordingSessionSdk(
          initSessionId: 'unused',
          historyError: StateError('session expired'),
        );
        final executor = AgentCronExecutor(sdk: sdk);

        final result = await executor.run(_task(sessionId: 'expired-session'));

        expect(result.success, isFalse);
        expect(
          result.error,
          allOf(
            contains('Cron session "expired-session" is unavailable'),
            contains('session expired'),
          ),
        );
        expect(sdk.initSessionCalls, 0);
        expect(sdk.getHistoryCalls, greaterThanOrEqualTo(1));
      },
    );

    test('stops a timed out reused session by the same sessionId', () async {
      final sdk = _RecordingSessionSdk(initSessionId: 'unused', hangChat: true);
      final executor = AgentCronExecutor(sdk: sdk);

      final result = await executor.run(
        _task(sessionId: 'timed-out-session', timeoutSeconds: 0),
      );

      expect(result.success, isFalse);
      expect(result.error, 'Cron task timed out.');
      expect(sdk.stoppedSessionId, 'timed-out-session');
      expect(sdk.initSessionCalls, 0);
    });
  });

  test('serializes CronTasks that share a sessionId', () async {
    final executor = _BlockingCronExecutor();
    final module = CronModule(
      store: InMemoryCronTaskStore(),
      executor: executor,
    );
    final first = await module.createTask(
      name: 'first',
      schedule: '0 9 * * *',
      source: 'test',
      sessionId: 'shared-session',
      enabled: false,
      spec: _spec(),
    );
    final second = await module.createTask(
      name: 'second',
      schedule: '0 9 * * *',
      source: 'test',
      sessionId: 'shared-session',
      enabled: false,
      spec: _spec(),
    );

    final firstRunFuture = module.runNow(first);
    await executor.started.future;
    final rejected = await module.runNow(second);
    executor.complete();
    final firstRun = await firstRunFuture;

    expect(rejected.status, CronRunStatus.cancelled);
    expect(rejected.error, contains('session "shared-session" is already'));
    expect(firstRun.status, CronRunStatus.succeeded);
    expect(executor.calls, 1);
  });
}

AgentCronSpec _spec({int timeoutSeconds = 3600}) {
  return AgentCronSpec(
    systemPrompt: 'You are a cron agent.',
    content: [Content(type: ContentType.text, message: 'Run the cron task.')],
    timeoutSeconds: timeoutSeconds,
  );
}

CronTaskDefinition _task({
  String? sessionId,
  String? timezone,
  int timeoutSeconds = 3600,
}) {
  return CronTaskDefinition(
    cronId: 'cron-session-test',
    name: 'session test',
    schedule: '0 9 * * *',
    source: 'test',
    sessionId: sessionId,
    timezone: timezone,
    concurrency: CronTaskConcurrencyPolicy.skipIfRunning,
    spec: _spec(timeoutSeconds: timeoutSeconds),
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
    status: CronTaskStatus.active,
  );
}

class _RecordingSessionSdk extends LiteAgentSDK {
  final String initSessionId;
  final Object? chatError;
  final Object? historyError;
  final bool hangChat;
  int initSessionCalls = 0;
  int getHistoryCalls = 0;
  final List<String> chatSessionIds = <String>[];
  final List<UserTask> userTasks = <UserTask>[];
  String? stoppedSessionId;

  _RecordingSessionSdk({
    required this.initSessionId,
    this.chatError,
    this.historyError,
    this.hangChat = false,
  }) : super(baseUrl: 'http://127.0.0.1:65535');

  @override
  Future<Session> initSession({Capability? capability}) async {
    initSessionCalls += 1;
    return Session(sessionId: initSessionId);
  }

  @override
  Future<void> chat(
    Session session,
    UserTask userTask,
    AgentMessageHandler agentMessageHandler,
  ) async {
    chatSessionIds.add(session.sessionId);
    userTasks.add(userTask);
    final error = chatError;
    if (error != null) {
      throw error;
    }
    if (hangChat) {
      await Completer<void>().future;
      return;
    }
    await agentMessageHandler.onMessage(
      session.sessionId,
      AgentMessage(
        sessionId: session.sessionId,
        taskId: 'session-test-task',
        role: AgentRoleType.LLM,
        to: AgentRoleType.USER,
        type: AgentMessageType.TEXT,
        content: 'done',
        createTime: DateTime.utc(2026, 1, 1),
      ),
    );
    await agentMessageHandler.onDone();
  }

  @override
  Future<List<AgentMessage>> getHistory(
    Session session, {
    int? page,
    int? pageSize,
  }) async {
    getHistoryCalls += 1;
    final error = historyError;
    if (error != null) {
      throw error;
    }
    return const <AgentMessage>[];
  }

  @override
  Future<void> stop(Session session, {String? taskId}) async {
    stoppedSessionId = session.sessionId;
  }
}

class _BlockingCronExecutor implements CronTaskExecutor {
  final Completer<void> started = Completer<void>();
  final Completer<void> _done = Completer<void>();
  int calls = 0;

  void complete() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<CronExecutionResult> run(
    CronTaskDefinition task, {
    DateTime? scheduledAt,
    Future<void> Function(AgentMessage message)? onMessage,
  }) async {
    calls += 1;
    if (!started.isCompleted) {
      started.complete();
    }
    await _done.future;
    return const CronExecutionResult();
  }
}
