import 'dart:async';

import 'package:agentos_kernel/src/kernel/cron/liteagent_executor.dart';
import 'package:agentos_kernel/src/kernel/cron/model.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Cron LiteAgent SDK resolution', () {
    test('executor uses latest sdk returned by resolver', () async {
      final oldSdk = _RecordingLiteAgentSdk(
        sessionId: 'old-session',
        responseText: 'old-response',
      );
      final newSdk = _RecordingLiteAgentSdk(
        sessionId: 'new-session',
        responseText: 'new-response',
      );
      var currentSdk = oldSdk;
      final executor = LiteAgentCronExecutor(
        sdkResolver: () => currentSdk,
        llmConfigResolver: () => LLMConfig(
          baseUrl: 'http://127.0.0.1:9000',
          apiKey: 'test-key',
          model: 'qwen-test',
        ),
        llmConfigListResolver: () => const <LLMConfig>[],
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
        ),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        status: CronTaskStatus.active,
      );

      final first = await executor.run(task);
      currentSdk = newSdk;
      final second = await executor.run(task);

      expect(first.success, isTrue);
      expect(first.liteAgentSessionId, 'old-session');
      expect(first.result?['content'], 'old-response');
      expect(oldSdk.initSessionCalls, 1);
      expect(oldSdk.chatCalls, 1);

      expect(second.success, isTrue);
      expect(second.liteAgentSessionId, 'new-session');
      expect(second.result?['content'], 'new-response');
      expect(newSdk.initSessionCalls, 1);
      expect(newSdk.chatCalls, 1);

      expect(oldSdk.initSessionCalls, 1);
      expect(oldSdk.chatCalls, 1);
    });

    test('executor prefers task llm config over resolver', () async {
      final sdk = _RecordingLiteAgentSdk(
        sessionId: 'override-session',
        responseText: 'override-response',
      );
      final executor = LiteAgentCronExecutor(
        sdk: sdk,
        llmConfigResolver: () => LLMConfig(
          baseUrl: 'http://127.0.0.1:9000',
          apiKey: 'fallback-key',
          model: 'fallback-model',
        ),
        llmConfigListResolver: () => const <LLMConfig>[],
      );
      final task = CronTaskDefinition(
        cronId: 'cron-2',
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
            apiKey: 'override-key',
            model: 'override-model',
            contextWindowSize: 128000,
          ),
        ),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        status: CronTaskStatus.active,
      );

      final result = await executor.run(task);
      final overrideConfig = sdk.lastCapability!.llmConfig;

      expect(result.success, isTrue);
      expect(sdk.lastCapability, isNotNull);
      expect(overrideConfig, isNotNull);
      expect(overrideConfig!.baseUrl, 'https://api.example.com/v1');
      expect(overrideConfig.model, 'override-model');
      expect(overrideConfig.contextWindowSize, 128000);
      expect(sdk.lastCapability!.llmConfigList, hasLength(1));
      expect(sdk.lastCapability!.llmConfigList!.single.model, 'override-model');
    });

    test(
      'executor skips status json text when picking display message',
      () async {
        final sdk = _HistoryLiteAgentSdk(
          sessionId: 'history-session',
          historyMessages: [
            AgentMessage(
              sessionId: 'history-session',
              taskId: 'root-task',
              role: AgentRoleType.LLM,
              to: AgentRoleType.USER,
              type: AgentMessageType.TEXT,
              content: 'starting task',
              createTime: DateTime(2026, 1, 1, 9, 0, 0),
            ),
            AgentMessage(
              sessionId: 'history-session',
              parentTaskId: 'root-task',
              taskId: 'report-task',
              role: AgentRoleType.LLM,
              to: AgentRoleType.USER,
              type: AgentMessageType.TEXT,
              content: '任务执行总结报告',
              createTime: DateTime(2026, 1, 1, 9, 1, 0),
            ),
            AgentMessage(
              sessionId: 'history-session',
              taskId: 'root-task',
              role: AgentRoleType.LLM,
              to: AgentRoleType.USER,
              type: AgentMessageType.TEXT,
              content: '{"status":"done","taskId":"2033816948801933312"}',
              createTime: DateTime(2026, 1, 1, 9, 2, 0),
            ),
          ],
        );
        final executor = LiteAgentCronExecutor(
          sdk: sdk,
          llmConfigResolver: () => LLMConfig(
            baseUrl: 'http://127.0.0.1:9000',
            apiKey: 'test-key',
            model: 'qwen-test',
          ),
          llmConfigListResolver: () => const <LLMConfig>[],
        );
        final task = CronTaskDefinition(
          cronId: 'cron-3',
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
          ),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          status: CronTaskStatus.active,
        );

        final result = await executor.run(task);

        expect(result.success, isTrue);
        expect(result.displayText, '任务执行总结报告');
        expect(result.result?['content'], '任务执行总结报告');
      },
    );

    test(
      'executor retries history until final user text becomes available',
      () async {
        final sdk = _DelayedHistoryLiteAgentSdk(
          sessionId: 'delayed-session',
          historySnapshots: [
            [
              AgentMessage(
                sessionId: 'delayed-session',
                taskId: 'task-1',
                role: AgentRoleType.AGENT,
                to: AgentRoleType.CLIENT,
                type: AgentMessageType.TASK_STATUS,
                content: {'status': 'done', 'taskId': 'task-1'},
                createTime: DateTime(2026, 1, 1, 9, 0, 0),
              ),
            ],
            [
              AgentMessage(
                sessionId: 'delayed-session',
                taskId: 'task-1',
                role: AgentRoleType.AGENT,
                to: AgentRoleType.USER,
                type: AgentMessageType.TEXT,
                content: '最终总结文本',
                createTime: DateTime(2026, 1, 1, 9, 0, 1),
              ),
              AgentMessage(
                sessionId: 'delayed-session',
                taskId: 'task-1',
                role: AgentRoleType.AGENT,
                to: AgentRoleType.CLIENT,
                type: AgentMessageType.TASK_STATUS,
                content: {'status': 'done', 'taskId': 'task-1'},
                createTime: DateTime(2026, 1, 1, 9, 0, 2),
              ),
            ],
          ],
        );
        final executor = LiteAgentCronExecutor(
          sdk: sdk,
          llmConfigResolver: () => LLMConfig(
            baseUrl: 'http://127.0.0.1:9000',
            apiKey: 'test-key',
            model: 'qwen-test',
          ),
          llmConfigListResolver: () => const <LLMConfig>[],
        );
        final task = CronTaskDefinition(
          cronId: 'cron-4',
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
          ),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          status: CronTaskStatus.active,
        );

        final result = await executor.run(task);

        expect(result.success, isTrue);
        expect(result.displayText, '最终总结文本');
        expect(result.result?['content'], '最终总结文本');
        expect(sdk.getHistoryCalls, greaterThanOrEqualTo(2));
      },
    );
  });
}

class _RecordingLiteAgentSdk extends LiteAgentSDK {
  final String sessionId;
  final String responseText;
  int initSessionCalls = 0;
  int chatCalls = 0;
  int getHistoryCalls = 0;
  Capability? lastCapability;

  _RecordingLiteAgentSdk({required this.sessionId, required this.responseText})
    : super(baseUrl: 'http://127.0.0.1:65535');

  @override
  Future<Session> initSession({Capability? capability, String? agentId}) async {
    initSessionCalls += 1;
    lastCapability = capability;
    return Session(sessionId: sessionId);
  }

  @override
  Future<void> chat(
    Session session,
    UserTask userTask,
    AgentMessageHandler agentMessageHandler,
  ) async {
    chatCalls += 1;
    unawaited(
      Future<void>(() async {
        await agentMessageHandler.onMessage(
          session.sessionId,
          AgentMessage(
            sessionId: session.sessionId,
            taskId: 'task-1',
            role: AgentRoleType.LLM,
            to: AgentRoleType.USER,
            type: AgentMessageType.TEXT,
            content: responseText,
            createTime: DateTime(2026, 1, 1),
          ),
        );
        await agentMessageHandler.onDone();
      }),
    );
  }

  @override
  Future<List<AgentMessage>> getHistory(Session session) async {
    getHistoryCalls += 1;
    return [
      AgentMessage(
        sessionId: session.sessionId,
        taskId: 'task-1',
        role: AgentRoleType.LLM,
        to: AgentRoleType.USER,
        type: AgentMessageType.TEXT,
        content: responseText,
        createTime: DateTime(2026, 1, 1),
      ),
    ];
  }
}

class _HistoryLiteAgentSdk extends LiteAgentSDK {
  final String sessionId;
  final List<AgentMessage> historyMessages;

  _HistoryLiteAgentSdk({required this.sessionId, required this.historyMessages})
    : super(baseUrl: 'http://127.0.0.1:65535');

  @override
  Future<Session> initSession({Capability? capability, String? agentId}) async {
    return Session(sessionId: sessionId);
  }

  @override
  Future<void> chat(
    Session session,
    UserTask userTask,
    AgentMessageHandler agentMessageHandler,
  ) async {
    unawaited(Future<void>(() async => agentMessageHandler.onDone()));
  }

  @override
  Future<List<AgentMessage>> getHistory(Session session) async {
    return historyMessages;
  }
}

class _DelayedHistoryLiteAgentSdk extends LiteAgentSDK {
  final String sessionId;
  final List<List<AgentMessage>> historySnapshots;
  int getHistoryCalls = 0;

  _DelayedHistoryLiteAgentSdk({
    required this.sessionId,
    required this.historySnapshots,
  }) : super(baseUrl: 'http://127.0.0.1:65535');

  @override
  Future<Session> initSession({Capability? capability, String? agentId}) async {
    return Session(sessionId: sessionId);
  }

  @override
  Future<void> chat(
    Session session,
    UserTask userTask,
    AgentMessageHandler agentMessageHandler,
  ) async {
    unawaited(Future<void>(() async => agentMessageHandler.onDone()));
  }

  @override
  Future<List<AgentMessage>> getHistory(Session session) async {
    final index = getHistoryCalls.clamp(0, historySnapshots.length - 1);
    getHistoryCalls += 1;
    return historySnapshots[index];
  }
}
