import 'dart:async';
import 'dart:io';

import 'package:agentos_kernel/src/kernel/agent/liteagent_client.dart';
import 'package:agentos_kernel/src/kernel/agent/llm_queue.dart';
import 'package:agentos_kernel/src/kernel/memory/drift_memory.dart';
import 'package:agentos_kernel/src/kernel/memory/memory_summarizer.dart';
import 'package:agentos_kernel/src/kernel/memory/model.dart';
import 'package:agentos_kernel/src/kernel/preference/agent_preference_extractor.dart';
import 'package:agentos_kernel/src/kernel/preference/preference.dart';
import 'package:agentos_kernel/src/kernel/preference/preference_extractor.dart';
import 'package:agentos_kernel/src/kernel/supervision/supervision.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_dart/opentool_client.dart' as ot;
import 'package:test/test.dart';

void main() {
  group('background LLM execution limits', () {
    test(
      'memory summary waits for terminal chat and uses strict limits',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'memory-summary-limits-',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final memory = DriftMemory.open(path: '${tempDir.path}/memory.sqlite');
        await memory.upsertMemoryItem(
          MemoryItem(
            id: 'session-1',
            type: agentMemoryItemType,
            sourceId: 'session-1',
            content: 'User prefers concise answers.',
            timestamp: DateTime.now(),
          ),
        );
        final sdk = _RecordingTerminalSdk(
          functionName: 'write_memory_summary',
          arguments: const {'text': 'User prefers concise answers.'},
          delayTerminal: true,
        );
        final summarizer = MemorySummarizer(
          memory: memory,
          llmQueue: _llmQueue(),
          client: LiteAgentClient(sdk: sdk),
          llmConfig: _llmConfig(),
          taskTimeout: const Duration(seconds: 45),
          minRecords: 1,
          enabled: false,
        );

        var completed = false;
        final future = summarizer.summarize().whenComplete(() {
          completed = true;
        });
        await sdk.functionCalled.future;
        final duplicate = summarizer.summarize(fullScan: true);
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);
        _expectSingleToolLimits(sdk.lastCapability, timeoutSeconds: 45);
        expect(sdk.lastToolReturn?.result['status'], 'completed');

        sdk.releaseTerminal();
        final summaries = await future;
        final duplicateSummaries = await duplicate;
        expect(summaries.single.text, 'User prefers concise answers.');
        expect(duplicateSummaries.single.text, 'User prefers concise answers.');
        expect(sdk.initSessionCalls, 1);
      },
    );

    test('preference extraction uses strict single-tool limits', () async {
      final sdk = _RecordingTerminalSdk(
        functionName: 'generate_preference',
        arguments: const {
          'text': ['Prefer concise answers'],
        },
      );
      final extractor = AgentPreferenceExtractor(
        llmQueue: _llmQueue(),
        client: LiteAgentClient(sdk: sdk),
        preference: InMemoryPreference(),
        llmConfig: _llmConfig(),
        systemPrompt: 'Extract stable preferences.',
        taskTimeout: const Duration(seconds: 30),
      );

      final preferences = await extractor.consume(
        PreferenceSourceRecord(
          jobId: 'task-1',
          userId: 'user-1',
          type: 'agent_memory',
          data: const {
            'content': ['Please keep answers concise.'],
          },
          timestamp: DateTime.now(),
        ),
      );

      _expectSingleToolLimits(sdk.lastCapability, timeoutSeconds: 30);
      expect(sdk.lastToolReturn?.result['status'], 'completed');
      expect(preferences.single.text, 'Prefer concise answers');
    });
  });
}

void _expectSingleToolLimits(
  Capability? capability, {
  required int timeoutSeconds,
}) {
  expect(capability, isNotNull);
  expect(capability!.timeoutSeconds, timeoutSeconds);
  expect(capability.maxLlmRequests, 2);
  expect(capability.maxToolRounds, 1);
  expect(capability.maxToolCalls, 1);
  expect(capability.maxConsecutiveIdenticalToolRounds, 1);
  expect(capability.maxTaskDurationSeconds, timeoutSeconds);
}

LlmQueue _llmQueue() {
  return LlmQueue(
    supervision: AdaptiveSupervision(
      ttftThreshold: const Duration(seconds: 5),
      tpsThreshold: 5,
    ),
  );
}

LLMConfig _llmConfig() {
  return LLMConfig(baseUrl: 'http://127.0.0.1:65535', model: 'test-model');
}

class _RecordingTerminalSdk extends LiteAgentSDK {
  final String functionName;
  final Map<String, dynamic> arguments;
  final bool delayTerminal;
  final Completer<void> functionCalled = Completer<void>();
  final Completer<void> _terminalGate = Completer<void>();

  Capability? lastCapability;
  ot.ToolReturn? lastToolReturn;
  int initSessionCalls = 0;

  _RecordingTerminalSdk({
    required this.functionName,
    required this.arguments,
    this.delayTerminal = false,
  }) : super(baseUrl: 'http://127.0.0.1:65535');

  @override
  Future<Session> initSession({Capability? capability, String? agentId}) async {
    initSessionCalls += 1;
    lastCapability = capability;
    return Session(sessionId: 'background-session');
  }

  @override
  Future<void> chat(
    Session session,
    UserTask userTask,
    AgentMessageHandler agentMessageHandler,
  ) async {
    lastToolReturn = await agentMessageHandler.onFunctionCall(
      session.sessionId,
      ot.FunctionCall(id: 'call-1', name: functionName, arguments: arguments),
    );
    if (!functionCalled.isCompleted) {
      functionCalled.complete();
    }
    if (delayTerminal) {
      await _terminalGate.future;
    }
    await agentMessageHandler.onDone();
  }

  void releaseTerminal() {
    if (!_terminalGate.isCompleted) {
      _terminalGate.complete();
    }
  }
}
