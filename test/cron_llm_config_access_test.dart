import 'dart:async';

import 'package:agentos_kernel/src/kernel/agent/config.dart';
import 'package:agentos_kernel/src/kernel/agent/model.dart';
import 'package:agentos_kernel/src/kernel/cron/llm_config_access.dart';
import 'package:agentos_kernel/src/kernel/cron/agent_executor.dart';
import 'package:agentos_kernel/src/kernel/cron/model.dart';
import 'package:agentos_kernel/src/kernel/supervision/supervision.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Cron LLM config resolution', () {
    test('starts without models and can recover after pool update', () async {
      final access = CronLlmConfigAccess(
        pool: null,
        llmQueue: null,
        supervision: AdaptiveSupervision(
          ttftThreshold: const Duration(seconds: 5),
          tpsThreshold: 5,
        ),
        profiler: null,
        mode: KernelMode.balanced,
        profileSuccessRateThreshold: 0.4,
        purpose: 'cron',
      );
      final sdk = _FakeLiteAgentSdk();
      final executor = AgentCronExecutor(
        sdk: sdk,
        llmConfigResolver: access.resolve,
        llmConfigListResolver: access.resolveAll,
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

      final failed = await executor.run(task);

      expect(failed.success, isFalse);
      expect(failed.error, 'No available LLM config for cron execution.');
      expect(sdk.initSessionCalls, 0);

      access.pool = LlmConfigPool.fromModels(const [
        KernelLlmModel(
          baseUrl: 'http://127.0.0.1:9000',
          model: 'qwen-test',
          description: 'test',
          parameters: '7B',
          paramsB: 7,
          quantization: 'Q4',
          sizeGB: 4,
        ),
      ]);

      final succeeded = await executor.run(task);

      expect(access.resolve(), isNotNull);
      expect(access.resolveAll(), hasLength(1));
      expect(succeeded.success, isTrue);
      expect(succeeded.error, isNull);
      expect(succeeded.result?['content'], 'cron finished');
      expect(succeeded.messages, hasLength(1));
      expect(sdk.initSessionCalls, 1);
    });
  });
}

class _FakeLiteAgentSdk extends LiteAgentSDK {
  int initSessionCalls = 0;
  int getHistoryCalls = 0;

  _FakeLiteAgentSdk() : super(baseUrl: 'http://127.0.0.1:65535');

  @override
  Future<Session> initSession({Capability? capability, String? agentId}) async {
    initSessionCalls += 1;
    return Session(sessionId: 'session-1');
  }

  @override
  Future<void> chat(
    Session session,
    UserTask userTask,
    AgentMessageHandler agentMessageHandler,
  ) async {
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
            content: 'cron finished',
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
        content: 'cron finished',
        createTime: DateTime(2026, 1, 1),
      ),
    ];
  }
}
