class MemorySnapshot {
  final String? scope;
  final Map<String, dynamic> data;
  final List<MemoryRecord> records;

  const MemorySnapshot({
    this.scope,
    Map<String, dynamic>? data,
    List<MemoryRecord>? records,
  })  : data = data ?? const {},
        records = records ?? const [];
}

class MemoryRecord {
  final String jobId;
  final String? userId;
  final String? sessionId;
  final String? scope;
  final String type;
  final Map<String, dynamic>? data;
  final DateTime timestamp;

  const MemoryRecord({
    required this.jobId,
    this.userId,
    this.sessionId,
    this.scope,
    required this.type,
    this.data,
    required this.timestamp,
  });
}
