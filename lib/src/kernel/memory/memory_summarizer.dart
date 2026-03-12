import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import '../agent/config.dart';
import '../agent/llm_queue.dart';
import '../agent/liteagent_client.dart';
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
  final Duration recentWindow;
  final int maxRecords;
  final int minRecords;
  final int maxScopesPerRun;
  final int keepLatestStateRecords;
  final bool enabled;

  Timer? _timer;
  bool _running = false;
  int _scopeCursor = 0;

  MemorySummarizer({
    required this.memory,
    required this.llmQueue,
    required this.client,
    required this.llmConfig,
    this.llmConfigResolver,
    this.logger,
    this.interval = const Duration(minutes: 5),
    this.recentWindow = const Duration(hours: 24),
    this.maxRecords = 200,
    this.minRecords = 20,
    this.maxScopesPerRun = 1,
    this.keepLatestStateRecords = 3,
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
    if (_running) {
      return;
    }
    if (!llmQueue.isIdle) {
      return;
    }
    _running = true;
    try {
      final scopes = await memory.listScopes();
      if (scopes.isEmpty) {
        return;
      }
      final runs = maxScopesPerRun <= 0 ? 1 : maxScopesPerRun;
      for (var i = 0; i < runs && scopes.isNotEmpty; i += 1) {
        final index = _scopeCursor % scopes.length;
        final scope = scopes[index];
        _scopeCursor = (_scopeCursor + 1) % scopes.length;
        await summarizeScope(scope: scope);
        if (!llmQueue.isIdle) {
          break;
        }
      }
    } catch (error) {
      logger?.error('Memory summarization failed.', error);
    } finally {
      _running = false;
    }
  }

  Future<MemoryRecord?> summarizeScope({
    required String scope,
    String? userId,
  }) async {
    final cutoff = DateTime.now().subtract(recentWindow);
    final latestSummaryTs = await memory.getLatestSummaryTimestamp(
      scope: scope,
      userId: userId,
    );
    final records = await memory.listRecords(
      scope: scope,
      userId: userId,
      after: latestSummaryTs,
      before: cutoff,
      limit: maxRecords,
      includeSummaries: false,
    );
    MemoryRecord? summaryRecord;
    if (records.length >= minRecords) {
      final prompt = _buildSummaryPrompt(
        records: records,
        scope: scope,
        userId: userId,
      );
      final response = await _runLlm(
        purpose: 'memory_summary',
        priority: 2,
        userId: userId,
        prompt: prompt,
        systemPrompt: _memorySummarySystemPrompt,
      );
      final summaryPayload = _parseSummaryPayload(response.text);
      final summaryText = _extractSummaryText(summaryPayload) ?? response.text;
      final summaryStart = records.first.timestamp;
      final summaryEnd = records.last.timestamp;
      summaryRecord = MemoryRecord(
        jobId: 'summary-${DateTime.now().microsecondsSinceEpoch}',
        userId: userId,
        sessionId: null,
        scope: scope,
        type: memorySummaryType,
        data: {
          'summaryText': summaryText,
          'summaryJson': summaryPayload,
          'summaryStart': summaryStart.toIso8601String(),
          'summaryEnd': summaryEnd.toIso8601String(),
          'recordCount': records.length,
        },
        timestamp: summaryEnd,
      );
      await memory.record(summaryRecord);
    }
    await _refreshMemoryStates(scope: scope, userId: userId, cutoff: cutoff);
    await _compactMemory(scope: scope, userId: userId);
    return summaryRecord;
  }

  Future<void> _refreshMemoryStates({
    required String scope,
    String? userId,
    required DateTime cutoff,
  }) async {
    await _refreshShortTermMemory(scope: scope, userId: userId, cutoff: cutoff);
    if (!llmQueue.isIdle) {
      return;
    }
    await _refreshLongTermMemory(scope: scope, userId: userId, cutoff: cutoff);
  }

  Future<void> _refreshShortTermMemory({
    required String scope,
    String? userId,
    required DateTime cutoff,
  }) async {
    final recentSummaries = await memory.listSummaryRecords(
      scope: scope,
      userId: userId,
      after: cutoff,
    );
    if (recentSummaries.isEmpty) {
      await memory.record(
        MemoryRecord(
          jobId: 'short-memory-${DateTime.now().microsecondsSinceEpoch}',
          userId: userId,
          sessionId: null,
          scope: scope,
          type: shortTermMemoryType,
          data: const {'summaryText': '', 'summaryJson': {}, 'sourceCount': 0},
          timestamp: DateTime.now(),
        ),
      );
      return;
    }
    final prompt = _buildSummaryAggregationPrompt(
      label: 'recent summaries',
      summaries: recentSummaries,
      scope: scope,
      userId: userId,
      priorMemory: null,
    );
    final response = await _runLlm(
      purpose: 'short_term_memory',
      priority: 3,
      userId: userId,
      prompt: prompt,
      systemPrompt: _memoryStateSystemPrompt,
    );
    final payload = _parseSummaryPayload(response.text);
    final summaryText = _extractSummaryText(payload) ?? response.text;
    await memory.record(
      MemoryRecord(
        jobId: 'short-memory-${DateTime.now().microsecondsSinceEpoch}',
        userId: userId,
        sessionId: null,
        scope: scope,
        type: shortTermMemoryType,
        data: {
          'summaryText': summaryText,
          'summaryJson': payload,
          'sourceCount': recentSummaries.length,
          'sourceStart': recentSummaries.first.timestamp.toIso8601String(),
          'sourceEnd': recentSummaries.last.timestamp.toIso8601String(),
        },
        timestamp: recentSummaries.last.timestamp,
      ),
    );
  }

  Future<void> _refreshLongTermMemory({
    required String scope,
    String? userId,
    required DateTime cutoff,
  }) async {
    final previous = await memory.getLatestStateRecord(
      type: longTermMemoryType,
      scope: scope,
      userId: userId,
    );
    final previousEnd = _sourceEnd(previous?.data);
    final promotedSummaries = await memory.listSummaryRecords(
      scope: scope,
      userId: userId,
      after: previousEnd,
      before: cutoff,
    );
    if (promotedSummaries.isEmpty && previous != null) {
      return;
    }
    if (promotedSummaries.isEmpty) {
      return;
    }
    final prompt = _buildSummaryAggregationPrompt(
      label: 'older summaries',
      summaries: promotedSummaries,
      scope: scope,
      userId: userId,
      priorMemory: previous?.data,
    );
    final response = await _runLlm(
      purpose: 'long_term_memory',
      priority: 4,
      userId: userId,
      prompt: prompt,
      systemPrompt: _longTermMemorySystemPrompt,
    );
    final payload = _parseSummaryPayload(response.text);
    final summaryText = _extractSummaryText(payload) ?? response.text;
    await memory.record(
      MemoryRecord(
        jobId: 'long-memory-${DateTime.now().microsecondsSinceEpoch}',
        userId: userId,
        sessionId: null,
        scope: scope,
        type: longTermMemoryType,
        data: {
          'summaryText': summaryText,
          'summaryJson': payload,
          'sourceCount': promotedSummaries.length,
          'sourceStart': promotedSummaries.first.timestamp.toIso8601String(),
          'sourceEnd': promotedSummaries.last.timestamp.toIso8601String(),
          if (previous?.data != null) 'previousLongTermMemory': previous!.data,
        },
        timestamp: promotedSummaries.last.timestamp,
      ),
    );
  }

  String _buildSummaryPrompt({
    required List<MemoryRecord> records,
    required String scope,
    String? userId,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('Summarize these memory records for future planning.');
    buffer.writeln('Scope: $scope');
    if (userId != null && userId.isNotEmpty) {
      buffer.writeln('User: $userId');
    }
    buffer.writeln('Records (JSON lines):');
    for (final record in records) {
      buffer.writeln(
        jsonEncode({
          'type': record.type,
          'data': record.data,
          'timestamp': record.timestamp.toIso8601String(),
        }),
      );
    }
    return buffer.toString();
  }

  String _buildSummaryAggregationPrompt({
    required String label,
    required List<MemoryRecord> summaries,
    required String scope,
    String? userId,
    Map<String, dynamic>? priorMemory,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('Scope: $scope');
    if (userId != null && userId.isNotEmpty) {
      buffer.writeln('User: $userId');
    }
    if (priorMemory != null && priorMemory.isNotEmpty) {
      buffer.writeln('Previous memory: ${jsonEncode(priorMemory)}');
    }
    buffer.writeln('Aggregate these $label into a compact memory state.');
    buffer.writeln('Summaries (JSON lines):');
    for (final summary in summaries) {
      buffer.writeln(
        jsonEncode({
          'timestamp': summary.timestamp.toIso8601String(),
          'data': summary.data,
        }),
      );
    }
    return buffer.toString();
  }

  String? _extractSummaryText(Map<String, dynamic>? payload) {
    if (payload == null) {
      return null;
    }
    final value = payload['summaryText'];
    if (value is String && value.trim().isNotEmpty) {
      return value;
    }
    return null;
  }

  Map<String, dynamic>? _parseSummaryPayload(String text) {
    final direct = _tryDecodeJsonMap(text);
    if (direct != null) {
      return direct;
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return _tryDecodeJsonMap(text.substring(start, end + 1));
    }
    return null;
  }

  Map<String, dynamic>? _tryDecodeJsonMap(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  Future<LiteAgentResponse> _runLlm({
    required String purpose,
    required int priority,
    required String? userId,
    required String prompt,
    required String systemPrompt,
  }) async {
    final effectiveConfig = normalizeLlmConfigForLiteAgent(
      llmConfigResolver?.call() ?? llmConfig,
    );
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
      userId: userId,
      run: (context) async {
        return client.chatSimple(
          llmConfig: effectiveConfig,
          systemPrompt: systemPrompt,
          userPrompt: prompt,
          context: context,
        );
      },
    );
  }

  DateTime? _sourceEnd(Map<String, dynamic>? data) {
    final value = data?['sourceEnd'];
    if (value is String) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  Future<void> _compactMemory({required String scope, String? userId}) async {
    final latestSummaryTs = await memory.getLatestSummaryTimestamp(
      scope: scope,
      userId: userId,
    );
    if (latestSummaryTs != null) {
      await memory.deleteDetailRecordsBefore(
        before: latestSummaryTs,
        scope: scope,
        userId: userId,
      );
    }

    final latestLongTerm = await memory.getLatestStateRecord(
      type: longTermMemoryType,
      scope: scope,
      userId: userId,
    );
    final coveredSummaryEnd = _sourceEnd(latestLongTerm?.data);
    if (coveredSummaryEnd != null) {
      await memory.deleteSummaryRecordsBefore(
        before: coveredSummaryEnd,
        scope: scope,
        userId: userId,
      );
    }

    await memory.pruneStateRecords(
      type: shortTermMemoryType,
      keepLatest: keepLatestStateRecords,
      scope: scope,
      userId: userId,
    );
    await memory.pruneStateRecords(
      type: longTermMemoryType,
      keepLatest: keepLatestStateRecords,
      scope: scope,
      userId: userId,
    );
  }

  static const String _memorySummarySystemPrompt =
      'You summarize memory records for future planning and preference learning. '
      'Return JSON only with fields: summaryText, keyFacts, preferences, openQuestions, '
      'intents, toolsUsed, timeRangeStart, timeRangeEnd, recordCount.';
  static const String _memoryStateSystemPrompt =
      'You aggregate recent memory summaries into a short-term memory state. '
      'Return JSON only with fields: summaryText, keyFacts, activeGoals, openThreads, preferences, recencyNotes.';
  static const String _longTermMemorySystemPrompt =
      'You update long-term memory from prior long-term memory and older summaries. '
      'Gradually forget stale details and keep only durable patterns. '
      'Return JSON only with fields: summaryText, keyFacts, enduringPreferences, recurringPatterns, durableContext.';
}
