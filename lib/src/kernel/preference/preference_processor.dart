import 'dart:async';

import '../agent/llm_queue.dart';
import '../logging/logger.dart';
import 'model.dart';
import 'preference_extractor.dart';

class PreferenceProcessor {
  final PreferenceExtractor extractor;
  final LlmQueue llmQueue;
  final KernelLogger? logger;
  final Duration interval;
  final int maxPerRun;
  final int queueLimit;
  final int minRecords;
  final bool enabled;

  final List<PreferenceSourceRecord> _pending = [];
  Timer? _timer;
  bool _running = false;

  PreferenceProcessor({
    required this.extractor,
    required this.llmQueue,
    this.logger,
    this.interval = const Duration(minutes: 2),
    this.maxPerRun = 2,
    this.queueLimit = 200,
    this.minRecords = 1,
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

  void enqueue(PreferenceSourceRecord record) {
    if (!enabled) {
      return;
    }
    _pending.add(record);
    if (_pending.length > queueLimit) {
      _pending.removeRange(0, _pending.length - queueLimit);
    }
  }

  Future<PreferenceExtractionTriggerResult> triggerNow() async {
    return _drainPending(limit: null);
  }

  Future<void> _tick() async {
    if (_running || _pending.isEmpty || !llmQueue.isIdle) {
      return;
    }
    await _drainPending(limit: maxPerRun);
  }

  Future<PreferenceExtractionTriggerResult> _drainPending({int? limit}) async {
    if (_running || _pending.isEmpty) {
      return PreferenceExtractionTriggerResult(
        preferences: const [],
        sourceRecordCount: _pending.length,
        minRequired: minRecords,
        reason: PreferenceExtractionTriggerResult.reasonEmpty,
      );
    }
    if (_pending.length < minRecords) {
      return PreferenceExtractionTriggerResult(
        preferences: const [],
        sourceRecordCount: _pending.length,
        minRequired: minRecords,
        reason: PreferenceExtractionTriggerResult.reasonInsufficientRecords,
      );
    }
    _running = true;
    try {
      final batchSize = limit == null
          ? _pending.length
          : (_pending.length < limit ? _pending.length : limit);
      if (batchSize < minRecords) {
        return PreferenceExtractionTriggerResult(
          preferences: const [],
          sourceRecordCount: _pending.length,
          minRequired: minRecords,
          reason: PreferenceExtractionTriggerResult.reasonInsufficientRecords,
        );
      }
      final batch = _pending.sublist(0, batchSize).toList(growable: false);
      _pending.removeRange(0, batchSize);
      final generated = <PreferenceEntry>[];
      for (final record in batch) {
        try {
          generated.addAll(await extractor.consume(record));
        } catch (error) {
          logger?.error('Preference extraction failed.', error);
        }
      }
      return PreferenceExtractionTriggerResult(
        preferences: generated,
        sourceRecordCount: batch.length,
        minRequired: minRecords,
        reason: generated.isEmpty
            ? PreferenceExtractionTriggerResult.reasonNoNewPreference
            : PreferenceExtractionTriggerResult.reasonGenerated,
      );
    } finally {
      _running = false;
    }
  }
}
