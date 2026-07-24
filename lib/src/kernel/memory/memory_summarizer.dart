import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_dart/opentool_client.dart';

import '../agent/config.dart';
import '../agent/llm_budget.dart';
import '../agent/liteagent_client.dart';
import '../agent/llm_queue.dart';
import '../agent/model.dart';
import '../logging/logger.dart';
import 'drift_memory.dart';
import 'model.dart';

class MemorySummarizer {
  final DriftMemory memory;
  final LlmQueue llmQueue;
  final LiteAgentClient client;
  final LLMConfig llmConfig;
  final LlmConfigResolver? llmConfigResolver;
  final KernelLogger? logger;
  final Duration interval;
  final Duration taskTimeout;
  final Duration recentWindow;
  final int maxRecords;
  final int minRecords;
  final int maxScopesPerRun;
  final bool enabled;

  Timer? _timer;
  Future<List<MemorySummary>>? _activeSummarization;
  bool _dirty = true;
  int _bucketCursor = 0;
  int _remainingDirtyBucketScans = MemorySummaryBucket.values.length;

  static const Duration _idleGapThreshold = Duration(hours: 1);
  static const Map<MemorySummaryBucket, int> _summaryCaps = {
    MemorySummaryBucket.recent: 8,
    MemorySummaryBucket.day: 8,
    MemorySummaryBucket.week: 10,
    MemorySummaryBucket.month: 12,
    MemorySummaryBucket.quarter: 12,
    MemorySummaryBucket.archive: 10,
  };

  MemorySummarizer({
    required this.memory,
    required this.llmQueue,
    required this.client,
    required this.llmConfig,
    this.llmConfigResolver,
    this.logger,
    this.interval = const Duration(minutes: 30),
    this.taskTimeout = const Duration(minutes: 2),
    this.recentWindow = const Duration(hours: 24),
    this.maxRecords = 200,
    this.minRecords = 1,
    this.maxScopesPerRun = 1,
    this.enabled = true,
  }) {
    if (enabled) {
      start();
    }
  }

  void start() {
    if (!enabled) {
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (_activeSummarization != null || !_dirty || !llmQueue.isIdle) {
      return;
    }
    try {
      await summarize();
    } catch (error) {
      logger?.error('Memory summarization failed.', error);
    }
  }

  Future<List<MemorySummary>> summarize({bool fullScan = false}) {
    final active = _activeSummarization;
    if (active != null) {
      return active;
    }
    late final Future<List<MemorySummary>> tracked;
    tracked = _summarize(fullScan: fullScan).whenComplete(() {
      if (identical(_activeSummarization, tracked)) {
        _activeSummarization = null;
      }
    });
    _activeSummarization = tracked;
    return tracked;
  }

  Future<List<MemorySummary>> _summarize({required bool fullScan}) async {
    final now = DateTime.now();
    final all = <MemorySummary>[];
    final buckets = MemorySummaryBucket.values;
    final scanLimit = fullScan || maxScopesPerRun <= 0
        ? buckets.length
        : (maxScopesPerRun < buckets.length ? maxScopesPerRun : buckets.length);
    if (fullScan || _remainingDirtyBucketScans <= 0) {
      _remainingDirtyBucketScans = buckets.length;
    }
    final scansThisRun = _remainingDirtyBucketScans < scanLimit
        ? _remainingDirtyBucketScans
        : scanLimit;
    for (var i = 0; i < scansThisRun; i++) {
      final bucket = buckets[_bucketCursor % buckets.length];
      _bucketCursor = (_bucketCursor + 1) % buckets.length;
      final summaries = await _buildBucketSummaries(bucket, now: now);
      await memory.saveMemorySummaries(bucket, summaries);
      all.addAll(summaries);
    }
    all.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _remainingDirtyBucketScans -= scansThisRun;
    _dirty = !fullScan && _remainingDirtyBucketScans > 0;
    return all;
  }

  void markDirty() {
    _dirty = true;
    _remainingDirtyBucketScans = MemorySummaryBucket.values.length;
  }

  Future<List<MemorySummary>> _buildBucketSummaries(
    MemorySummaryBucket bucket, {
    required DateTime now,
  }) async {
    final items = await _loadBucketItems(bucket, now: now);
    if (items.length < minRecords) {
      return const [];
    }
    final segments = _coalesceSegments(
      _splitActiveSegments(items),
      _summaryCaps[bucket] ?? 8,
    );
    final summaries = <MemorySummary>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final text = await _summarizeSegment(bucket, segment, ordinal: i + 1);
      if (text == null || text.trim().isEmpty) {
        continue;
      }
      summaries.add(
        MemorySummary(
          id: '${bucket.name}-${segment.start.millisecondsSinceEpoch}-${segment.end.millisecondsSinceEpoch}',
          text: text.trim(),
          sourceIds: segment.sourceIds,
          sourceStartAt: segment.start,
          sourceEndAt: segment.end,
          updatedAt: now,
          bucket: bucket,
        ),
      );
    }
    return summaries;
  }

  Future<List<_MemorySource>> _loadBucketItems(
    MemorySummaryBucket bucket, {
    required DateTime now,
  }) async {
    if (bucket == MemorySummaryBucket.archive) {
      final cutoff = now.subtract(const Duration(days: 90));
      final items = await memory.listMemoryItems(
        type: agentMemoryItemType,
        before: cutoff,
        limit: maxRecords,
        descending: true,
      );
      return items.reversed.map(_MemorySource.fromItem).toList(growable: false);
    }
    final window = bucket.window;
    if (window == null) {
      return const [];
    }
    final items = await memory.listMemoryItems(
      type: agentMemoryItemType,
      after: now.subtract(window),
      limit: maxRecords,
      descending: true,
    );
    return items.reversed.map(_MemorySource.fromItem).toList(growable: false);
  }

  List<_MemorySegmentInput> _splitActiveSegments(List<_MemorySource> items) {
    if (items.isEmpty) {
      return const [];
    }
    final segments = <_MemorySegmentInput>[];
    var currentItems = <_MemorySource>[items.first];
    var currentStart = items.first.timestamp;
    var currentEnd = items.first.timestamp;
    for (var i = 1; i < items.length; i++) {
      final item = items[i];
      final gap = item.timestamp.difference(currentEnd);
      if (gap > _idleGapThreshold) {
        segments.add(
          _MemorySegmentInput(
            items: currentItems,
            start: currentStart,
            end: currentEnd,
          ),
        );
        currentItems = <_MemorySource>[item];
        currentStart = item.timestamp;
        currentEnd = item.timestamp;
        continue;
      }
      currentItems.add(item);
      currentEnd = item.timestamp;
    }
    segments.add(
      _MemorySegmentInput(
        items: currentItems,
        start: currentStart,
        end: currentEnd,
      ),
    );
    return segments;
  }

  List<_MemorySegmentInput> _coalesceSegments(
    List<_MemorySegmentInput> segments,
    int maxSegments,
  ) {
    if (segments.length <= maxSegments || maxSegments <= 0) {
      return segments;
    }
    final groupSize = (segments.length / maxSegments).ceil();
    final merged = <_MemorySegmentInput>[];
    for (var index = 0; index < segments.length; index += groupSize) {
      final slice = segments.sublist(
        index,
        index + groupSize > segments.length
            ? segments.length
            : index + groupSize,
      );
      final items = <_MemorySource>[];
      for (final segment in slice) {
        items.addAll(segment.items);
      }
      merged.add(
        _MemorySegmentInput(
          items: items,
          start: slice.first.start,
          end: slice.last.end,
        ),
      );
    }
    return merged;
  }

  Future<String?> _summarizeSegment(
    MemorySummaryBucket bucket,
    _MemorySegmentInput segment, {
    required int ordinal,
  }) async {
    final prompt = _buildSegmentPrompt(bucket, segment, ordinal: ordinal);
    final payload = await _runSummaryPrompt(
      purpose: 'memory_summary_${bucket.name}',
      priority: 9,
      systemPrompt: _summarySystemPrompt(bucket),
      prompt: prompt,
    );
    final text = payload['text'];
    if (text is String && text.trim().isNotEmpty) {
      return text.trim();
    }
    return null;
  }

  String _buildSegmentPrompt(
    MemorySummaryBucket bucket,
    _MemorySegmentInput segment, {
    required int ordinal,
  }) {
    final buffer = StringBuffer();
    buffer.writeln(
      'Create one memory summary for this ${bucket.name} segment.',
    );
    buffer.writeln(
      'Keep only information that may help understand future user requests.',
    );
    buffer.writeln('Do not keep trivial chatter or stale details.');
    buffer.writeln(
      'Call the write_memory_summary function directly with exactly one text argument.',
    );
    buffer.writeln('Segment #$ordinal');
    buffer.writeln(
      'Time range: ${segment.start.toUtc().toIso8601String()} -> ${segment.end.toUtc().toIso8601String()}',
    );
    buffer.writeln('Items:');
    for (final item in segment.items) {
      buffer.writeln(
        '[${item.id}] ${item.timestamp.toUtc().toIso8601String()}',
      );
      buffer.writeln(item.content);
      buffer.writeln();
    }
    return buffer.toString().trim();
  }

  Future<Map<String, dynamic>> _runSummaryPrompt({
    required String purpose,
    required int priority,
    required String systemPrompt,
    required String prompt,
  }) async {
    final effectiveConfig = resolveLlmInputBudget(
      fallbackConfig: llmConfig,
      resolver: llmConfigResolver,
    ).config;
    final modelKey = buildLlmModelKey(
      baseUrl: effectiveConfig.baseUrl,
      model: effectiveConfig.model,
      apiKey: effectiveConfig.apiKey,
    );
    return llmQueue.enqueue(
      purpose: purpose,
      priority: priority,
      weight: 2,
      modelKey: modelKey,
      run: (context) async {
        final sdk = client.sdk;
        final taskTimeoutSeconds = taskTimeout.inSeconds > 0
            ? taskTimeout.inSeconds
            : 1;
        final capability = Capability(
          llmConfig: effectiveConfig,
          systemPrompt: systemPrompt,
          callbackOpenTool: CallbackOpenTool(opentool: _summaryToolSpecJson()),
          timeoutSeconds: taskTimeoutSeconds,
          maxLlmRequests: 2,
          maxToolRounds: 1,
          maxToolCalls: 1,
          maxConsecutiveIdenticalToolRounds: 1,
          maxTaskDurationSeconds: taskTimeoutSeconds,
        );
        final session = await sdk.initSession(capability: capability);
        final task = UserTask(
          content: [Content(type: ContentType.text, message: prompt)],
          isChunk: false,
        );
        final completer = Completer<Map<String, dynamic>>();
        final handler = _SummaryToolHandler(
          onFirstToken: context.markFirstToken,
          onMessageCallback: (message) => _recordTokenUsage(message, context),
          onPayload: (payload) {
            if (!completer.isCompleted) {
              completer.complete(payload);
            }
          },
          onDoneCallback: () {
            if (!completer.isCompleted) {
              completer.complete(const {});
            }
          },
        );
        await sdk.chat(session, task, handler);
        return completer.future;
      },
    );
  }

  String _summarySystemPrompt(MemorySummaryBucket bucket) {
    return 'You condense memory into one concise ${bucket.name} summary. '
        'Call the write_memory_summary function directly with a single text field only. '
        'Keep only information that may help future request understanding.';
  }

  String _summaryToolSpecJson() {
    final spec = {
      'opentool': '1.1.0',
      'info': {
        'title': 'Kernel Memory Summary Tools',
        'description': 'Write one concise memory summary.',
        'version': '1.0.0',
      },
      'functions': [
        {
          'name': 'write_memory_summary',
          'description':
              'Write one concise memory summary. Call this function directly; do not wrap it in another function.',
          'parameters': [
            {
              'name': 'text',
              'description': 'The concise memory summary text.',
              'required': true,
              'schema': {
                'type': 'string',
                'description': 'The concise memory summary text.',
              },
            },
          ],
        },
      ],
    };
    return jsonEncode(spec);
  }
}

void _recordTokenUsage(AgentMessage message, LlmCallContext context) {
  final usage = message.completions?.usage;
  if (usage == null) {
    return;
  }
  context.setTotalTokens(usage.totalTokens);
  final contextUsageRatio = usage.contextUsageRatio;
  if (contextUsageRatio != null) {
    context.setContextUsageRatio(contextUsageRatio.toDouble());
  }
}

class _SummaryToolHandler extends AgentMessageHandler {
  final void Function() onFirstToken;
  final void Function(AgentMessage message) onMessageCallback;
  final void Function(Map<String, dynamic> payload) onPayload;
  final void Function() onDoneCallback;

  _SummaryToolHandler({
    required this.onFirstToken,
    required this.onMessageCallback,
    required this.onPayload,
    required this.onDoneCallback,
  });

  @override
  Future<ToolReturn> onFunctionCall(
    String sessionId,
    FunctionCall functionCall,
  ) async {
    onFirstToken();
    final call = _resolveToolCall(functionCall);
    if (call.name == 'write_memory_summary') {
      onPayload(call.arguments);
      return ToolReturn(
        id: functionCall.id,
        result: {
          'status': 'completed',
          'message': 'Memory summary stored. Do not call this tool again.',
        },
      );
    }
    return ToolReturn(
      id: functionCall.id,
      result: {
        'status': 'ignored',
        'message': 'Unknown function: ${functionCall.name}',
      },
    );
  }

  @override
  Future<void> onMessage(String sessionId, AgentMessage agentMessage) async {
    onFirstToken();
    onMessageCallback(agentMessage);
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
}

_ResolvedToolCall _resolveToolCall(FunctionCall functionCall) {
  final originalName = functionCall.name.trim();
  final args = Map<String, dynamic>.from(functionCall.arguments);
  final normalized = originalName.toLowerCase();
  if (normalized == 'fn' ||
      normalized == 'function' ||
      normalized == 'function_call' ||
      normalized == 'tool_call') {
    final nestedName = args['name'] ?? args['function'] ?? args['tool'];
    final nestedArgs = args['arguments'] ?? args['args'] ?? args['input'];
    if (nestedName is String && nestedName.trim().isNotEmpty) {
      return _ResolvedToolCall(
        name: nestedName.trim(),
        arguments: _argumentsMap(nestedArgs, fallback: args),
      );
    }
  }
  return _ResolvedToolCall(name: originalName, arguments: args);
}

Map<String, dynamic> _argumentsMap(Object? value, {required Map fallback}) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      return Map<String, dynamic>.from(fallback);
    }
  }
  return Map<String, dynamic>.from(fallback);
}

class _ResolvedToolCall {
  final String name;
  final Map<String, dynamic> arguments;

  const _ResolvedToolCall({required this.name, required this.arguments});
}

class _MemorySource {
  final String id;
  final String content;
  final DateTime timestamp;

  const _MemorySource({
    required this.id,
    required this.content,
    required this.timestamp,
  });

  factory _MemorySource.fromItem(MemoryItem item) {
    return _MemorySource(
      id: item.id,
      content: item.content,
      timestamp: item.timestamp,
    );
  }
}

class _MemorySegmentInput {
  final List<_MemorySource> items;
  final DateTime start;
  final DateTime end;

  const _MemorySegmentInput({
    required this.items,
    required this.start,
    required this.end,
  });

  List<String> get sourceIds => items
      .map((item) => item.id)
      .where((id) => id.isNotEmpty)
      .toList(growable: false);
}
