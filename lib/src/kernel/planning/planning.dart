import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_dart/opentool_client.dart';

import '../execution/execution_agent.dart';
import '../execution/open_tool_directory.dart';
import '../agent/config.dart';
import '../agent/liteagent_client.dart';
import '../agent/llm_queue.dart';
import '../agent/model.dart';
import '../memory/model.dart';
import '../perception/model.dart';
import '../preference/model.dart';
import 'model.dart';

abstract class Planning {
  Future<PlanResult> create(
    Percept percept,
    MemorySnapshot memory,
    PreferenceSnapshot preference,
  );
}

class RuleBasedPlanning extends Planning {
  final double minConfidence;
  final double minDelta;
  final Set<String> confirmationActions;
  final OpenToolDirectory? openToolDirectory;

  RuleBasedPlanning({
    this.minConfidence = 0.6,
    this.minDelta = 0.15,
    Set<String>? confirmationActions,
    this.openToolDirectory,
  }) : confirmationActions = confirmationActions ?? const {'delete', 'run'};

  @override
  Future<PlanResult> create(
    Percept percept,
    MemorySnapshot memory,
    PreferenceSnapshot preference,
  ) async {
    if (openToolDirectory != null) {
      await openToolDirectory!.ensureLoaded();
    }
    if (percept.candidates.isEmpty) {
      return const PlanResult(
        intent: null,
        decision: PlanDecision.rejected,
        reason: 'No viable intent candidates.',
      );
    }
    final sorted = List<CandidateIntent>.from(percept.candidates)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final best = sorted.first;
    final secondBest = sorted.length > 1 ? sorted[1] : null;
    if (best.confidence < minConfidence ||
        (secondBest != null &&
            (best.confidence - secondBest.confidence) < minDelta)) {
      return PlanResult(
        intent: null,
        decision: PlanDecision.rejected,
        reason: 'Intent confidence is too low.',
      );
    }
    final intent = _buildIntent(best, memory, preference);
    if (intent == null) {
      return const PlanResult(
        intent: null,
        decision: PlanDecision.rejected,
        reason: 'No matching OpenTool for action.',
      );
    }
    if (confirmationActions.contains(best.action)) {
      return PlanResult(
        intent: intent,
        decision: PlanDecision.needsConfirmation,
        reason: 'Action requires confirmation.',
        confirmation: ConfirmationRequest(
          prompt: 'This action could be destructive. Do you want to proceed?',
        ),
      );
    }
    return PlanResult(
      intent: intent,
      decision: PlanDecision.ready,
      reason: null,
    );
  }

  Intent? _buildIntent(
    CandidateIntent best,
    MemorySnapshot memory,
    PreferenceSnapshot preference,
  ) {
    final directory = openToolDirectory;
    if (directory == null) {
      return Intent(
        action: best.action,
        target: best.target,
        params: {
          'memoryScope': memory.scope,
          'preferenceUserId': preference.userId,
          if (best.params != null) ...best.params!,
        },
        confidence: best.confidence,
      );
    }
    final toolId = directory.resolveToolIdForFunction(best.action);
    if (toolId == null) {
      return null;
    }
    final params = <String, dynamic>{
      'toolId': toolId,
      'function': best.action,
      'arguments': best.params ?? const {},
      'memoryScope': memory.scope,
      'preferenceUserId': preference.userId,
    };
    return Intent(
      action: 'open_tool',
      target: best.target,
      params: params,
      confidence: best.confidence,
    );
  }
}

class LiteAgentPlanning extends Planning {
  final LlmQueue llmQueue;
  final LiteAgentClient client;
  final LLMConfig llmConfig;
  final LlmConfigResolver? llmConfigResolver;
  final String systemPrompt;
  final int memoryLimit;
  final OpenToolDirectory openToolDirectory;
  final List<ExecutionAgentTemplate> executionAgents;

  LiteAgentPlanning({
    required this.llmQueue,
    required this.client,
    required this.llmConfig,
    required this.systemPrompt,
    this.llmConfigResolver,
    this.memoryLimit = 5,
    OpenToolDirectory? openToolDirectory,
    List<ExecutionAgentTemplate>? executionAgents,
  })  : openToolDirectory = openToolDirectory ?? OpenToolDirectory(),
        executionAgents = executionAgents ?? const [];

  @override
  Future<PlanResult> create(
    Percept percept,
    MemorySnapshot memory,
    PreferenceSnapshot preference,
  ) async {
    final prompt = await _buildPrompt(percept, memory, preference);
    final effectiveConfig = llmConfigResolver?.call() ?? llmConfig;
    final modelKey = buildLlmModelKey(
      baseUrl: effectiveConfig.baseUrl,
      model: effectiveConfig.model,
      apiKey: effectiveConfig.apiKey,
    );
    final result = await llmQueue.enqueue(
      purpose: 'planning',
      priority: 1,
      weight: 5,
      modelKey: modelKey,
      run: (context) async {
        final sdk = LiteAgentSDK(
          baseUrl: client.baseUrl,
          apiKey: client.apiKey,
        );
        final capability = Capability(
          llmConfig: effectiveConfig,
          systemPrompt: systemPrompt,
          callbackOpenTool: CallbackOpenTool(
            opentool: _planningToolSpecJson(),
          ),
        );
        final session = await sdk.initSession(capability: capability);
        final task = UserTask(
          taskId: _safeJobId(context.meta.id),
          content: [
            Content(type: ContentType.text, message: prompt),
          ],
          isChunk: true,
        );
        final completer = Completer<PlanResult>();
        final handler = _PlanningAgentHandler(
          memory: memory,
          preference: preference,
          onFirstToken: context.markFirstToken,
          onPlan: (plan) {
            if (!completer.isCompleted) {
              completer.complete(plan);
            }
          },
          onDoneCallback: () {
            if (!completer.isCompleted) {
              completer.complete(
                const PlanResult(
                  intent: null,
                  decision: PlanDecision.rejected,
                  reason: 'No planning tool call.',
                ),
              );
            }
          },
        );
        await sdk.chat(session, task, handler);
        return completer.future;
      },
    );
    return result;
  }

  Future<String> _buildPrompt(
    Percept percept,
    MemorySnapshot memory,
    PreferenceSnapshot preference,
  ) async {
    final buffer = StringBuffer();
    buffer.writeln('You are planning the next action based on intent candidates.');
    buffer.writeln('You must call exactly one planning tool function.');
    buffer.writeln('If no action should be taken, call plan_reject.');
    buffer.writeln('Candidates:');
    for (final candidate in percept.candidates) {
      buffer.writeln(
        jsonEncode({
          'action': candidate.action,
          'target': candidate.target,
          'params': candidate.params,
          'confidence': candidate.confidence,
        }),
      );
    }
    buffer.writeln('Memory scope: ${memory.scope}');
    buffer.writeln('Recent memory records:');
    final records = _recentRecords(memory.records);
    for (final record in records) {
      buffer.writeln(
        jsonEncode({
          'type': record.type,
          'data': record.data,
          'timestamp': record.timestamp.toIso8601String(),
        }),
      );
    }
    buffer.writeln('Preferences: ${jsonEncode(preference.preferences)}');
    buffer.writeln('User id: ${preference.userId}');
    buffer.writeln('Available OpenTools:');
    if (openToolDirectory.isEmpty) {
      buffer.writeln('[]');
    } else {
      buffer.writeln(jsonEncode(await openToolDirectory.summaries()));
    }
    buffer.writeln('Execution agents:');
    if (executionAgents.isEmpty) {
      buffer.writeln('[]');
    } else {
      buffer.writeln(
        jsonEncode(
          executionAgents
              .map(
                (agent) => {
                  'id': agent.id,
                  'name': agent.name,
                  'description': agent.description,
                },
              )
              .toList(),
        ),
      );
    }
    return buffer.toString();
  }

  List<MemoryRecord> _recentRecords(List<MemoryRecord> records) {
    final summaries =
        records.where((record) => record.type == 'MEMORY_SUMMARY').toList();
    final details =
        records.where((record) => record.type != 'MEMORY_SUMMARY').toList();
    final detailSlice = (memoryLimit <= 0 || details.length <= memoryLimit)
        ? details
        : details.sublist(details.length - memoryLimit);
    final combined = [...summaries, ...detailSlice];
    combined.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return combined;
  }

  String _planningToolSpecJson() {
    final spec = {
      'opentool': '1.1.0',
      'info': {
        'title': 'Kernel Planning Tools',
        'description': 'Planning tool calls for kernel.',
        'version': '1.0.0',
      },
      'functions': [
        {
          'name': 'plan_open_tool',
          'description':
              'Choose an OpenTool function to execute (open_tool intent).',
          'parameters': [
            {
              'name': 'toolId',
              'description': 'OpenTool id to call.',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'function',
              'description': 'Function name to call.',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'arguments',
              'description': 'Function arguments.',
              'required': true,
              'schema': {'type': 'object'},
            },
            {
              'name': 'confidence',
              'description': 'Confidence 0-1.',
              'required': false,
              'schema': {'type': 'number'},
            },
            {
              'name': 'reason',
              'description': 'Short reasoning.',
              'required': false,
              'schema': {'type': 'string'},
            },
            {
              'name': 'needsConfirmation',
              'description': 'Whether to require user confirmation.',
              'required': false,
              'schema': {'type': 'boolean'},
            },
            {
              'name': 'confirmationPrompt',
              'description': 'Prompt to show for confirmation.',
              'required': false,
              'schema': {'type': 'string'},
            },
          ],
        },
        {
          'name': 'plan_execution_agent',
          'description': 'Use an execution agent (execution_agent intent).',
          'parameters': [
            {
              'name': 'agentId',
              'description': 'Execution agent id.',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'content',
              'description': 'List of LiteAgent content objects.',
              'required': false,
              'schema': {'type': 'array'},
            },
            {
              'name': 'text',
              'description': 'Fallback text task.',
              'required': false,
              'schema': {'type': 'string'},
            },
            {
              'name': 'confidence',
              'description': 'Confidence 0-1.',
              'required': false,
              'schema': {'type': 'number'},
            },
            {
              'name': 'reason',
              'description': 'Short reasoning.',
              'required': false,
              'schema': {'type': 'string'},
            },
            {
              'name': 'needsConfirmation',
              'description': 'Whether to require user confirmation.',
              'required': false,
              'schema': {'type': 'boolean'},
            },
            {
              'name': 'confirmationPrompt',
              'description': 'Prompt to show for confirmation.',
              'required': false,
              'schema': {'type': 'string'},
            },
          ],
        },
        {
          'name': 'plan_reject',
          'description': 'Reject the plan when no valid action exists.',
          'parameters': [
            {
              'name': 'reason',
              'description': 'Rejection reason.',
              'required': false,
              'schema': {'type': 'string'},
            },
          ],
        },
      ],
    };
    return jsonEncode(spec);
  }

  String _safeJobId(String id) {
    if (id.length <= 36) {
      return id;
    }
    return id.substring(0, 36);
  }
}

class _PlanningAgentHandler extends AgentMessageHandler {
  final MemorySnapshot memory;
  final PreferenceSnapshot preference;
  final void Function() onFirstToken;
  final void Function(PlanResult plan) onPlan;
  final void Function() onDoneCallback;

  _PlanningAgentHandler({
    required this.memory,
    required this.preference,
    required this.onFirstToken,
    required this.onPlan,
    required this.onDoneCallback,
  });

  @override
  Future<ToolReturn> onFunctionCall(
    String sessionId,
    FunctionCall functionCall,
  ) async {
    onFirstToken();
    final args = Map<String, dynamic>.from(functionCall.arguments);
    switch (functionCall.name) {
      case 'plan_open_tool':
        final plan = _planOpenTool(args);
        onPlan(plan);
        return ToolReturn(
          id: functionCall.id,
          result: {'status': 'accepted'},
        );
      case 'plan_execution_agent':
        final plan = _planExecutionAgent(args);
        onPlan(plan);
        return ToolReturn(
          id: functionCall.id,
          result: {'status': 'accepted'},
        );
      case 'plan_reject':
        final plan = PlanResult(
          intent: null,
          decision: PlanDecision.rejected,
          reason: args['reason'] is String
              ? args['reason'] as String
              : 'Plan rejected.',
        );
        onPlan(plan);
        return ToolReturn(
          id: functionCall.id,
          result: {'status': 'accepted'},
        );
      default:
        return ToolReturn(
          id: functionCall.id,
          result: {'status': 'ignored', 'message': 'Unknown planning tool.'},
        );
    }
  }

  @override
  Future<void> onMessage(String sessionId, AgentMessage agentMessage) async {
    onFirstToken();
  }

  @override
  Future<void> onChunk(
    String sessionId,
    AgentMessageChunk agentMessageChunk,
  ) async {
    onFirstToken();
  }

  @override
  Future<void> onDone() async {
    onDoneCallback();
  }

  @override
  Future<void> onError(Exception e) async {
    onDoneCallback();
  }

  PlanResult _planOpenTool(Map<String, dynamic> args) {
    final toolId = args['toolId'];
    final functionName = args['function'];
    final arguments = args['arguments'];
    if (toolId is! String || functionName is! String) {
      return const PlanResult(
        intent: null,
        decision: PlanDecision.rejected,
        reason: 'Missing toolId/function for open_tool.',
      );
    }
    final params = <String, dynamic>{
      'toolId': toolId,
      'function': functionName,
      'arguments': arguments is Map<String, dynamic> ? arguments : {},
      'memoryScope': memory.scope,
      'preferenceUserId': preference.userId,
    };
    final confidence = _parseConfidence(args['confidence']);
    final intent = Intent(
      action: 'open_tool',
      target: args['target'] is String ? args['target'] as String : null,
      params: params,
      confidence: confidence,
    );
    return _wrapDecision(intent, args);
  }

  PlanResult _planExecutionAgent(Map<String, dynamic> args) {
    final agentId = args['agentId'];
    if (agentId is! String || agentId.isEmpty) {
      return const PlanResult(
        intent: null,
        decision: PlanDecision.rejected,
        reason: 'Missing agentId for execution_agent.',
      );
    }
    final params = <String, dynamic>{
      'agentId': agentId,
      if (args['content'] is List) 'content': args['content'],
      if (args['text'] is String) 'text': args['text'],
      'memoryScope': memory.scope,
      'preferenceUserId': preference.userId,
    };
    final confidence = _parseConfidence(args['confidence']);
    final intent = Intent(
      action: 'execution_agent',
      target: null,
      params: params,
      confidence: confidence,
    );
    return _wrapDecision(intent, args);
  }

  PlanResult _wrapDecision(Intent intent, Map<String, dynamic> args) {
    final needsConfirmation = args['needsConfirmation'] == true;
    if (!needsConfirmation) {
      return PlanResult(
        intent: intent,
        decision: PlanDecision.ready,
        reason: args['reason'] is String ? args['reason'] as String : null,
      );
    }
    final prompt = args['confirmationPrompt'];
    return PlanResult(
      intent: intent,
      decision: PlanDecision.needsConfirmation,
      reason: args['reason'] is String
          ? args['reason'] as String
          : 'Action requires confirmation.',
      confirmation: ConfirmationRequest(
        prompt: prompt is String && prompt.isNotEmpty
            ? prompt
            : 'This action could be destructive. Do you want to proceed?',
      ),
    );
  }

  double _parseConfidence(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return 0.6;
  }
}
