import 'package:agentos_kernel/src/kernel/agent/liteagent_client.dart';
import 'package:agentos_kernel/src/kernel/agent/model.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  const plannerSkill = '''
---
name: task-planner
description: Break work into clear ordered steps before execution.
---

1. Summarize the goal.
2. Propose a short plan.
3. Execute step by step.
''';

  group('LiteAgentClient', () {
    test('chatSimple forwards skills to SimpleCapability', () async {
      final sdk = _RecordingLiteAgentSdk();
      final client = LiteAgentClient(sdk: sdk);

      final response = await client.chatSimple(
        llmConfig: LLMConfig(
          baseUrl: 'https://example.com/v1',
          apiKey: 'test-key',
          model: 'test-model',
        ),
        systemPrompt: 'Use configured skills.',
        userPrompt: 'Plan this task.',
        skills: const [plannerSkill],
        context: LlmCallContext(
          meta: LlmRequestMeta(
            id: 'req-1',
            purpose: 'test',
            priority: 0,
            weight: 1,
            modelKey: 'test-model-key',
          ),
          onFirstToken: (_) {},
        ),
      );

      expect(response.text, 'ok');
      expect(sdk.lastSimpleCapability, isNotNull);
      expect(sdk.lastSimpleCapability!.skills, const [plannerSkill]);
    });
  });
}

class _RecordingLiteAgentSdk extends LiteAgentSDK {
  SimpleCapability? lastSimpleCapability;

  _RecordingLiteAgentSdk() : super(baseUrl: 'https://liteagent.example');

  @override
  Future<Session> initSimple(SimpleCapability capability) async {
    lastSimpleCapability = capability;
    return Session(sessionId: 'session-1');
  }

  @override
  Future<AgentMessage> chatSimple(Session session, UserTask userTaskDto) async {
    return AgentMessage(
      sessionId: session.sessionId,
      taskId: 'task-1',
      role: AgentRoleType.LLM,
      to: AgentRoleType.USER,
      type: AgentMessageType.TEXT,
      content: 'ok',
      createTime: DateTime(2026, 1, 1),
    );
  }
}
