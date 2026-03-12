import 'model.dart';

abstract class Memory {
  Future<MemorySnapshot> getSnapshot({String? scope});
  Future<List<MemoryRecord>> listRecords({
    String? scope,
    String? userId,
    String? type,
    DateTime? after,
    DateTime? before,
    int offset = 0,
    int? limit,
    bool includeSummaries = false,
  });
  Future<void> record(MemoryRecord record);
  Future<void> deleteRecord(String id);
}

class InMemoryMemory extends Memory {
  final List<MemoryRecord> _records = [];
  int _nextId = 0;

  @override
  Future<MemorySnapshot> getSnapshot({String? scope}) async {
    final records = scope == null
        ? List<MemoryRecord>.from(_records)
        : _records.where((record) => record.scope == scope).toList();
    return MemorySnapshot(scope: scope, records: records);
  }

  @override
  Future<void> record(MemoryRecord record) async {
    _records.add(
      MemoryRecord(
        id: record.id ?? (++_nextId).toString(),
        jobId: record.jobId,
        userId: record.userId,
        sessionId: record.sessionId,
        scope: record.scope,
        type: record.type,
        data: record.data,
        timestamp: record.timestamp,
      ),
    );
  }

  @override
  Future<List<MemoryRecord>> listRecords({
    String? scope,
    String? userId,
    String? type,
    DateTime? after,
    DateTime? before,
    int offset = 0,
    int? limit,
    bool includeSummaries = false,
  }) async {
    var records = _records
        .where((record) {
          if (!includeSummaries && record.type == 'MEMORY_SUMMARY') {
            return false;
          }
          if (scope != null && scope.isNotEmpty && record.scope != scope) {
            return false;
          }
          if (userId != null && userId.isNotEmpty && record.userId != userId) {
            return false;
          }
          if (type != null && type.isNotEmpty && record.type != type) {
            return false;
          }
          if (after != null && !record.timestamp.isAfter(after)) {
            return false;
          }
          if (before != null && record.timestamp.isAfter(before)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
    records.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (offset > 0) {
      if (offset >= records.length) {
        return const [];
      }
      records = records.sublist(offset);
    }
    if (limit != null && limit > 0 && records.length > limit) {
      records = records.sublist(0, limit);
    }
    return records;
  }

  @override
  Future<void> deleteRecord(String id) async {
    _records.removeWhere((record) => record.id == id);
  }
}
