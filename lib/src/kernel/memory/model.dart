class MemorySnapshot {
  final String? scope;
  final Map<String, dynamic> data;
  final Map<String, dynamic> shortTermMemory;
  final Map<String, dynamic> longTermMemory;
  final List<MemoryRecord> records;

  const MemorySnapshot({
    this.scope,
    Map<String, dynamic>? data,
    Map<String, dynamic>? shortTermMemory,
    Map<String, dynamic>? longTermMemory,
    List<MemoryRecord>? records,
  }) : data = data ?? const {},
       shortTermMemory = shortTermMemory ?? const {},
       longTermMemory = longTermMemory ?? const {},
       records = records ?? const [];
}

const String memorySummaryType = 'MEMORY_SUMMARY';
const String shortTermMemoryType = 'SHORT_TERM_MEMORY';
const String longTermMemoryType = 'LONG_TERM_MEMORY';

class MemoryRecord {
  final String? id;
  final String jobId;
  final String? userId;
  final String? sessionId;
  final String? scope;
  final String type;
  final Map<String, dynamic>? data;
  final DateTime timestamp;

  const MemoryRecord({
    this.id,
    required this.jobId,
    this.userId,
    this.sessionId,
    this.scope,
    required this.type,
    this.data,
    required this.timestamp,
  });
}
