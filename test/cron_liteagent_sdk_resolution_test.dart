import 'dart:async';
import 'dart:convert';

import 'package:agentos_kernel/src/kernel/cron/daemon_open_spec_provider.dart';
import 'package:agentos_kernel/src/kernel/cron/agent_executor.dart';
import 'package:agentos_kernel/src/kernel/cron/model.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_daemon/opentool_daemon_client.dart';
import 'package:opentool_dart/opentool_client.dart' as ot;
import 'package:opentool_dart/opentool_schema.dart';
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
      final executor = AgentCronExecutor(
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
      expect(oldSdk.lastCapability!.maxTaskDurationSeconds, 3600);

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
      final executor = AgentCronExecutor(
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

    test('executor debug prints callback tool catalog', () async {
      final sdk = _RecordingLiteAgentSdk(
        sessionId: 'debug-session',
        responseText: 'debug-response',
      );
      final executor = AgentCronExecutor(
        sdk: sdk,
        llmConfigResolver: () => LLMConfig(
          baseUrl: 'http://127.0.0.1:9000',
          apiKey: 'test-key',
          model: 'qwen-test',
        ),
        llmConfigListResolver: () => const <LLMConfig>[],
        daemonToolCatalogResolver: () async => [
          CronDaemonToolCatalogItem(
            toolId: 'tool-a',
            alias: 'search',
            status: 'running',
            spec: OpenTool(
              opentool: '1.1.0',
              info: Info(
                title: 'Tool A',
                description: 'Search tool',
                version: '1.0.0',
              ),
              functions: [
                FunctionModel(
                  name: 'search_news',
                  description: 'Search news',
                  parameters: const [],
                ),
              ],
            ),
          ),
        ],
        daemonClientFactory: (host, port) => _NoopDaemonClient(),
      );
      final task = CronTaskDefinition(
        cronId: 'cron-debug',
        name: 'debug-report',
        schedule: '*/5 * * * *',
        source: 'api',
        concurrency: CronTaskConcurrencyPolicy.skipIfRunning,
        spec: AgentCronSpec(
          systemPrompt: 'You are a cron agent.',
          content: [
            Content(type: ContentType.text, message: 'Generate debug output.'),
          ],
        ),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        status: CronTaskStatus.active,
      );

      final printed = <String>[];
      await runZoned(
        () async {
          final result = await executor.run(task);
          expect(result.success, isTrue);
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );

      final capabilityLog = printed
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .firstWhere(
            (payload) =>
                payload['tag'] == 'cron_executor_stage' &&
                payload['stage'] == 'executor_capability_built',
          );

      final data = capabilityLog['data'] as Map<String, dynamic>;
      final capability = data['capability'] as Map<String, dynamic>;
      final callbackOpenTool =
          capability['callbackOpenTool'] as Map<String, dynamic>;
      final functions = callbackOpenTool['functions'] as List<dynamic>;
      final firstFunction = functions.single as Map<String, dynamic>;

      expect(callbackOpenTool['toolCount'], 1);
      expect(functions, hasLength(1));
      expect(firstFunction['toolId'], 'tool-a');
      expect(firstFunction['alias'], 'search');
      expect(firstFunction['functionName'], 'search_news');
      expect(firstFunction['syntheticName'], 'daemon_tool-a__search_news');
      expect(firstFunction['isStreaming'], isFalse);
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
              content: 'Task execution summary report',
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
        final executor = AgentCronExecutor(
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
        expect(result.displayText, 'Task execution summary report');
        expect(result.result?['content'], 'Task execution summary report');
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
                content: 'Final summary text',
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
        final executor = AgentCronExecutor(
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
        expect(result.displayText, 'Final summary text');
        expect(result.result?['content'], 'Final summary text');
        expect(sdk.getHistoryCalls, greaterThanOrEqualTo(2));
      },
    );

    test('executor uses daemon call for non-stream functions even from stream callback', () async {
      final sdk = _StreamFunctionLiteAgentSdk(sessionId: 'stream-session');
      final daemonClient = _RecordingModeAwareDaemonClient();
      final executor = AgentCronExecutor(
        sdk: sdk,
        llmConfigResolver: () => LLMConfig(
          baseUrl: 'http://127.0.0.1:9000',
          apiKey: 'test-key',
          model: 'qwen-test',
        ),
        llmConfigListResolver: () => const <LLMConfig>[],
        daemonToolCatalogResolver: () async => [
          CronDaemonToolCatalogItem(
            toolId: 'tool-a',
            alias: 'search',
            status: 'running',
            spec: OpenTool(
              opentool: '1.1.0',
              info: Info(
                title: 'Tool A',
                description: 'Search tool',
                version: '1.0.0',
              ),
              functions: [
                FunctionModel(
                  name: 'search_news',
                  description: 'Search news',
                  parameters: const [],
                ),
              ],
            ),
          ),
        ],
        daemonClientFactory: (host, port) => daemonClient,
      );
      final task = CronTaskDefinition(
        cronId: 'cron-stream',
        name: 'stream-report',
        schedule: '*/5 * * * *',
        source: 'api',
        concurrency: CronTaskConcurrencyPolicy.skipIfRunning,
        spec: AgentCronSpec(
          systemPrompt: 'You are a cron agent.',
          timeoutSeconds: 1,
          content: [
            Content(type: ContentType.text, message: 'Run stream tool.'),
          ],
        ),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        status: CronTaskStatus.active,
      );

      final result = await executor.run(task);

      expect(result.success, isTrue);
      expect(daemonClient.callCount, 1);
      expect(daemonClient.streamCallCount, 0);
      expect(sdk.observedEvents, hasLength(1));
      expect(sdk.observedEvents.single.eventType, ot.EventType.DONE);
      expect(sdk.observedEvents.single.toolReturn.result, {
        'status': 'ok',
        'mode': 'call',
      });
    });

    test(
      'executor falls back to empty daemon catalog when resolver fails',
      () async {
        final sdk = _RecordingLiteAgentSdk(
          sessionId: 'fallback-session',
          responseText: 'fallback-response',
        );
        final executor = AgentCronExecutor(
          sdk: sdk,
          llmConfigResolver: () => LLMConfig(
            baseUrl: 'http://127.0.0.1:9000',
            apiKey: 'test-key',
            model: 'qwen-test',
          ),
          llmConfigListResolver: () => const <LLMConfig>[],
          daemonToolCatalogResolver: () async {
            throw StateError('daemon load returned 404');
          },
        );
        final task = CronTaskDefinition(
          cronId: 'cron-fallback',
          name: 'fallback-report',
          schedule: '*/5 * * * *',
          source: 'api',
          concurrency: CronTaskConcurrencyPolicy.skipIfRunning,
          spec: AgentCronSpec(
            systemPrompt: 'You are a cron agent.',
            content: [
              Content(
                type: ContentType.text,
                message: 'Generate fallback output.',
              ),
            ],
          ),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          status: CronTaskStatus.active,
        );

        final result = await executor.run(task);

        expect(result.success, isTrue);
        expect(result.liteAgentSessionId, 'fallback-session');
        expect(result.result?['content'], 'fallback-response');
        expect(sdk.lastCapability, isNotNull);
        expect(sdk.lastCapability!.callbackOpenTool, isNotNull);
      },
    );

    test(
      'executor converts terminal chat errors into failed results',
      () async {
        final sdk = _FailingChatLiteAgentSdk();
        final executor = AgentCronExecutor(
          sdk: sdk,
          llmConfigResolver: () =>
              LLMConfig(baseUrl: 'http://127.0.0.1:9000', model: 'qwen-test'),
        );
        final task = CronTaskDefinition(
          cronId: 'cron-failed-chat',
          name: 'failed-chat',
          schedule: '*/5 * * * *',
          source: 'api',
          concurrency: CronTaskConcurrencyPolicy.skipIfRunning,
          spec: AgentCronSpec(
            systemPrompt: 'You are a cron agent.',
            content: [
              Content(type: ContentType.text, message: 'Run the task.'),
            ],
          ),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          status: CronTaskStatus.active,
        );

        final result = await executor.run(task);

        expect(result.success, isFalse);
        expect(result.liteAgentSessionId, 'failed-chat-session');
        expect(result.error, contains('tool_loop_limit_exceeded'));
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
  Future<Session> initSession({Capability? capability}) async {
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
  }

  @override
  Future<List<AgentMessage>> getHistory(
    Session session, {
    int? page,
    int? pageSize,
  }) async {
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
  Future<Session> initSession({Capability? capability}) async {
    return Session(sessionId: sessionId);
  }

  @override
  Future<void> chat(
    Session session,
    UserTask userTask,
    AgentMessageHandler agentMessageHandler,
  ) async {
    await agentMessageHandler.onDone();
  }

  @override
  Future<List<AgentMessage>> getHistory(
    Session session, {
    int? page,
    int? pageSize,
  }) async {
    return historyMessages;
  }
}

class _FailingChatLiteAgentSdk extends LiteAgentSDK {
  _FailingChatLiteAgentSdk() : super(baseUrl: 'http://127.0.0.1:65535');

  @override
  Future<Session> initSession({Capability? capability}) async {
    return Session(sessionId: 'failed-chat-session');
  }

  @override
  Future<void> chat(
    Session session,
    UserTask userTask,
    AgentMessageHandler agentMessageHandler,
  ) async {
    throw Exception('tool_loop_limit_exceeded');
  }

  @override
  Future<List<AgentMessage>> getHistory(
    Session session, {
    int? page,
    int? pageSize,
  }) async => const [];
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
  Future<Session> initSession({Capability? capability}) async {
    return Session(sessionId: sessionId);
  }

  @override
  Future<void> chat(
    Session session,
    UserTask userTask,
    AgentMessageHandler agentMessageHandler,
  ) async {
    await agentMessageHandler.onDone();
  }

  @override
  Future<List<AgentMessage>> getHistory(
    Session session, {
    int? page,
    int? pageSize,
  }) async {
    final index = getHistoryCalls.clamp(0, historySnapshots.length - 1);
    getHistoryCalls += 1;
    return historySnapshots[index];
  }
}

class _NoopDaemonClient extends DaemonClient {
  _NoopDaemonClient() : super(host: '127.0.0.1', port: 19627);
}

class _StreamFunctionLiteAgentSdk extends LiteAgentSDK {
  final String sessionId;
  final List<EventToolReturn> observedEvents = <EventToolReturn>[];

  _StreamFunctionLiteAgentSdk({required this.sessionId})
    : super(baseUrl: 'http://127.0.0.1:65535');

  @override
  Future<Session> initSession({Capability? capability}) async {
    return Session(sessionId: sessionId);
  }

  @override
  Future<void> chat(
    Session session,
    UserTask userTask,
    AgentMessageHandler agentMessageHandler,
  ) async {
    await agentMessageHandler.onStreamFunctionCall(
      session.sessionId,
      ot.FunctionCall(
        id: 'call-1',
        name: 'daemon_tool-a__search_news',
        arguments: const {'query': 'latest AI news'},
      ),
      observedEvents.add,
    );
    if (observedEvents.isNotEmpty) {
      await agentMessageHandler.onDone();
    }
  }

  @override
  Future<List<AgentMessage>> getHistory(
    Session session, {
    int? page,
    int? pageSize,
  }) async => const [];
}

class _RecordingModeAwareDaemonClient extends DaemonClient {
  int callCount = 0;
  int streamCallCount = 0;

  _RecordingModeAwareDaemonClient() : super(host: '127.0.0.1', port: 19627);

  @override
  Future<ot.ToolReturn> callTool(
    String toolId,
    ot.FunctionCall functionCall,
  ) async {
    callCount += 1;
    return ot.ToolReturn(
      id: functionCall.id,
      result: {'status': 'ok', 'mode': 'call'},
    );
  }

  @override
  Future<void> streamCallTool(
    String toolId,
    ot.FunctionCall functionCall, {
    required void Function(String event, Map<String, dynamic> data) onEvent,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    streamCallCount += 1;
    onEvent(
      ot.EventType.DONE,
      ot.ToolReturn(
        id: functionCall.id,
        result: {'status': 'ok', 'mode': 'stream'},
      ).toJson(),
    );
  }
}
