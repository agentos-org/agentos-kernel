import 'model.dart';

abstract class Memory {
  Future<MemorySnapshot> getSnapshot({String? scope});
  Future<void> record(MemoryRecord record);
}

class InMemoryMemory extends Memory {
  final List<MemoryRecord> _records = [];

  @override
  Future<MemorySnapshot> getSnapshot({String? scope}) async {
    final records = scope == null
        ? List<MemoryRecord>.from(_records)
        : _records.where((record) => record.scope == scope).toList();
    return MemorySnapshot(scope: scope, records: records);
  }

  @override
  Future<void> record(MemoryRecord record) async {
    _records.add(record);
  }
}
