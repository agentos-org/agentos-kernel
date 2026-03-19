import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import '../agent/config.dart';
import '../logging/logger.dart';
import 'executor.dart';
import 'model.dart';

class LiteAgentCronExecutor implements CronTaskExecutor {
  static const int _historyRetryAttempts = 3;
  static const Duration _historyRetryDelay = Duration(milliseconds: 150);

  final LiteAgentSDK? sdk;
  final LiteAgentSDK Function()? sdkResolver;
  final KernelLogger? logger;
  final LLMConfig? Function()? llmConfigResolver;
  final List<LLMConfig> Function()? llmConfigListResolver;
  final Future<List<OpenSpec>> Function()? daemonOpenSpecResolver;

  LiteAgentCronExecutor({
    this.sdk,
    this.sdkResolver,
    this.logger,
    this.llmConfigResolver,
    this.llmConfigListResolver,
    this.daemonOpenSpecResolver,
  }) : assert(sdk != null || sdkResolver != null);

  @override
  Future<CronExecutionResult> run(
    CronTaskDefinition task, {
    Future<void> Function(AgentMessage message)? onMessage,
  }) async {
    final activeSdk = sdkResolver?.call() ?? sdk;
    if (activeSdk == null) {
      return const CronExecutionResult(
        error: 'No available LiteAgent SDK for cron execution.',
      );
    }
    final llmConfig = task.spec.llmConfig ?? llmConfigResolver?.call();
    if (llmConfig == null) {
      return const CronExecutionResult(
        error: 'No available LLM config for cron execution.',
      );
    }
    final normalizedLlmConfig = normalizeLlmConfigForLiteAgent(llmConfig);
    final normalizedLlmConfigList = (task.spec.llmConfig != null)
        ? <LLMConfig>[normalizedLlmConfig]
        : llmConfigListResolver
              ?.call()
              .map(normalizeLlmConfigForLiteAgent)
              .toList(growable: false);
    final capability = task.spec.toCapability(
      llmConfig: normalizedLlmConfig,
      llmConfigList: normalizedLlmConfigList,
      openSpecList: await daemonOpenSpecResolver?.call(),
    );
    final session = await activeSdk.initSession(capability: capability);
    _debugPrintStage('executor_session_initialized', {
      'sessionId': session.sessionId,
      'cronId': task.cronId,
    });
    final completer = Completer<CronExecutionResult>();
    void completeIfPending({String? error}) {
      if (completer.isCompleted) {
        return;
      }
      completer.complete(
        CronExecutionResult(
          liteAgentSessionId: session.sessionId,
          error: error,
        ),
      );
    }

    final messages = <AgentMessage>[];
    final handler = _CronAgentMessageHandler(
      onMessage: (message) async {
        _debugPrintStage('executor_on_message', {
          'sessionId': session.sessionId,
          'taskId': message.taskId,
          'parentTaskId': message.parentTaskId,
          'role': message.role,
          'to': message.to,
          'type': message.type,
          'content': _normalizeContent(message.content),
        });
        messages.add(message);
        if (_isRootTaskDoneMessage(message)) {
          _debugPrintStage('executor_task_status_done', {
            'sessionId': session.sessionId,
            'taskId': message.taskId,
            'parentTaskId': message.parentTaskId,
          });
          completeIfPending();
        }
        await onMessage?.call(message);
      },
      onDone: () {
        _debugPrintStage('executor_on_done', {
          'sessionId': session.sessionId,
          'messageCount': messages.length,
        });
        completeIfPending();
      },
      onError: (error) {
        _debugPrintStage('executor_on_error', {
          'sessionId': session.sessionId,
          'messageCount': messages.length,
          'error': error.toString(),
        });
        completeIfPending(error: error.toString());
      },
    );
    await activeSdk.chat(session, task.spec.toUserTask(), handler);
    _debugPrintStage('executor_chat_started', {
      'sessionId': session.sessionId,
      'cronId': task.cronId,
    });
    final baseResult = await completer.future.timeout(
      Duration(seconds: task.spec.timeoutSeconds),
      onTimeout: () => CronExecutionResult(
        liteAgentSessionId: session.sessionId,
        error: 'Cron task timed out.',
      ),
    );
    _debugPrintStage('executor_base_result', {
      'sessionId': session.sessionId,
      'success': baseResult.success,
      if (baseResult.error != null) 'error': baseResult.error,
    });
    var timeline = await _resolveMessages(
      activeSdk,
      session,
      collectedMessages: messages,
    );
    if (baseResult.success) {
      timeline = await _resolveMessagesUntilDisplayable(
        activeSdk,
        session,
        collectedMessages: messages,
        initialTimeline: timeline,
      );
    }
    final displayMessage = _pickDisplayableMessage(timeline);
    final summaryMessage = displayMessage ?? _pickSummaryMessage(timeline);
    _debugPrintResolvedRun(
      sessionId: session.sessionId,
      baseResult: baseResult,
      timeline: timeline,
      displayMessage: displayMessage,
      summaryMessage: summaryMessage,
    );
    return CronExecutionResult(
      liteAgentSessionId: baseResult.liteAgentSessionId,
      error: baseResult.error,
      result: _messageToResult(summaryMessage),
      messages: timeline,
      displayMessageId: displayMessage?.taskId,
      displayText: _extractDisplayText(displayMessage),
    );
  }

  Future<List<AgentMessage>> _resolveMessagesUntilDisplayable(
    LiteAgentSDK sdk,
    Session session, {
    required List<AgentMessage> collectedMessages,
    required List<AgentMessage> initialTimeline,
  }) async {
    var timeline = initialTimeline;
    if (_pickDisplayableMessage(timeline) != null) {
      return timeline;
    }
    for (var attempt = 0; attempt < _historyRetryAttempts; attempt++) {
      _debugPrintStage('executor_history_retry_wait', {
        'sessionId': session.sessionId,
        'attempt': attempt + 1,
      });
      await Future<void>.delayed(_historyRetryDelay);
      timeline = await _resolveMessages(
        sdk,
        session,
        collectedMessages: collectedMessages,
      );
      if (_pickDisplayableMessage(timeline) != null) {
        return timeline;
      }
    }
    return timeline;
  }

  void _debugPrintResolvedRun({
    required String sessionId,
    required CronExecutionResult baseResult,
    required List<AgentMessage> timeline,
    required AgentMessage? displayMessage,
    required AgentMessage? summaryMessage,
  }) {
    final hasTaskStatus = timeline.any(
      (message) => message.type == AgentMessageType.TASK_STATUS,
    );
    if (!hasTaskStatus) {
      return;
    }
    final payload = <String, dynamic>{
      'tag': 'cron_executor_debug',
      'sessionId': sessionId,
      'success': baseResult.success,
      if (baseResult.error != null) 'error': baseResult.error,
      'timelineCount': timeline.length,
      'displayMessage': _debugMessage(displayMessage),
      'summaryMessage': _debugMessage(summaryMessage),
      'timeline': timeline.map(_debugMessage).toList(growable: false),
    };
    print(jsonEncode(payload));
  }

  Map<String, dynamic>? _debugMessage(AgentMessage? message) {
    if (message == null) {
      return null;
    }
    return {
      'taskId': message.taskId,
      'parentTaskId': message.parentTaskId,
      'role': message.role,
      'to': message.to,
      'type': message.type,
      'createTime': message.createTime.toIso8601String(),
      'content': _normalizeContent(message.content),
      if (message.reasoningContent != null)
        'reasoningContent': message.reasoningContent,
    };
  }

  Future<List<AgentMessage>> _resolveMessages(
    LiteAgentSDK sdk,
    Session session, {
    required List<AgentMessage> collectedMessages,
  }) async {
    final merged = <String, AgentMessage>{};
    for (final message in collectedMessages) {
      merged[_messageKey(message)] = message;
    }
    _debugPrintStage('executor_history_fetch_start', {
      'sessionId': session.sessionId,
      'collectedCount': collectedMessages.length,
    });
    try {
      final history = await sdk.getHistory(session);
      _debugPrintStage('executor_history_fetch_done', {
        'sessionId': session.sessionId,
        'historyCount': history.length,
      });
      for (final message in history) {
        merged[_messageKey(message)] = message;
      }
    } catch (error) {
      logger?.warn(
        'Failed to load cron history for ${session.sessionId}: $error',
      );
    }
    final values = merged.values.toList(growable: false);
    values.sort((a, b) => a.createTime.compareTo(b.createTime));
    _debugPrintStage('executor_timeline_resolved', {
      'sessionId': session.sessionId,
      'timelineCount': values.length,
    });
    return List<AgentMessage>.unmodifiable(values);
  }

  void _debugPrintStage(String stage, Map<String, dynamic> data) {
    print(
      jsonEncode({
        'tag': 'cron_executor_stage',
        'stage': stage,
        'timestamp': DateTime.now().toIso8601String(),
        'data': data,
      }),
    );
  }

  AgentMessage? _pickDisplayableMessage(List<AgentMessage> messages) {
    for (final message in messages.reversed) {
      final text = _extractDisplayText(message);
      if (text == null) {
        continue;
      }
      if (_looksLikeStructuredStatusText(text)) {
        continue;
      }
      return message;
    }
    for (final message in messages.reversed) {
      final text = _extractDisplayText(message);
      if (text == null) {
        continue;
      }
      return message;
    }
    return null;
  }

  AgentMessage? _pickSummaryMessage(List<AgentMessage> messages) {
    final rootTaskId = _resolveRootTaskId(messages);
    if (rootTaskId != null) {
      for (final message in messages.reversed) {
        if (message.taskId == rootTaskId) {
          return message;
        }
      }
    }
    if (messages.isEmpty) {
      return null;
    }
    return messages.last;
  }

  String? _resolveRootTaskId(List<AgentMessage> messages) {
    for (final message in messages) {
      if (message.parentTaskId == null || message.parentTaskId!.isEmpty) {
        return message.taskId;
      }
    }
    return null;
  }

  String? _extractDisplayText(AgentMessage? message) {
    if (message == null) {
      return null;
    }
    if (message.to != AgentRoleType.USER) {
      return null;
    }
    if (message.type != AgentMessageType.TEXT) {
      return null;
    }
    final content = _normalizeContent(message.content);
    if (content is! String) {
      return null;
    }
    final text = content.trim();
    if (text.isEmpty) {
      return null;
    }
    return text;
  }

  bool _isRootTaskDoneMessage(AgentMessage message) {
    if (message.parentTaskId != null && message.parentTaskId!.isNotEmpty) {
      return false;
    }
    if (message.type != AgentMessageType.TASK_STATUS) {
      return false;
    }
    final content = _normalizeContent(message.content);
    if (content is! Map) {
      return false;
    }
    final status = content['status'];
    return status is String && status == 'done';
  }

  bool _looksLikeStructuredStatusText(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
      return false;
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) {
        return false;
      }
      final keys = decoded.keys.map((key) => key.toString()).toSet();
      if (!keys.contains('status')) {
        return false;
      }
      return keys.contains('taskId') ||
          keys.contains('task_id') ||
          keys.contains('parentTaskId') ||
          keys.contains('parent_task_id');
    } catch (_) {
      return false;
    }
  }

  String _messageKey(AgentMessage message) {
    final content = _normalizeContent(message.content);
    return [
      message.sessionId,
      message.taskId,
      message.role,
      message.to,
      message.type,
      message.createTime.toIso8601String(),
      jsonEncode(content),
      message.reasoningContent ?? '',
    ].join('|');
  }

  Map<String, dynamic> _messageToResult(AgentMessage? message) {
    if (message == null) {
      return const {'message': 'No agent message received.'};
    }
    final content = message.content;
    return {
      'taskId': message.taskId,
      'role': message.role,
      'type': message.type,
      'content': _normalizeContent(content),
      if (message.reasoningContent != null)
        'reasoningContent': message.reasoningContent,
    };
  }

  Object? _normalizeContent(Object? content) {
    if (content == null ||
        content is String ||
        content is num ||
        content is bool) {
      return content;
    }
    if (content is Map<String, dynamic> || content is List) {
      return content;
    }
    try {
      return jsonDecode(jsonEncode(content));
    } catch (_) {
      logger?.warn('Failed to normalize cron agent content: $content');
      return content.toString();
    }
  }
}

class _CronAgentMessageHandler extends AgentMessageHandler {
  final Future<void> Function(AgentMessage message) _onMessage;
  final void Function() _onDone;
  final void Function(Exception error) _onError;

  _CronAgentMessageHandler({
    required Future<void> Function(AgentMessage message) onMessage,
    required void Function() onDone,
    required void Function(Exception error) onError,
  }) : _onMessage = onMessage,
       _onDone = onDone,
       _onError = onError;

  @override
  Future<void> onChunk(
    String sessionId,
    AgentMessageChunk agentMessageChunk,
  ) async {}

  @override
  Future<void> onDone() async {
    _onDone();
  }

  @override
  Future<void> onError(Exception e) async {
    _onError(e);
  }

  @override
  Future<void> onMessage(String sessionId, AgentMessage agentMessage) async {
    await _onMessage(agentMessage);
  }
}
