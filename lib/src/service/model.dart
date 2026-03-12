class KernelSources {
  static const String cli = 'cli';
  static const String web = 'web';
  static const String mobile = 'mobile';
  static const String api = 'api';
  static const String test = 'test';

  const KernelSources._();
}

class MemoryRecordListItem {
  final String id;
  final String text;
  final DateTime timestamp;

  const MemoryRecordListItem({
    required this.id,
    required this.text,
    required this.timestamp,
  });
}

class PreferenceListItem {
  final String key;
  final String text;

  const PreferenceListItem({required this.key, required this.text});
}

class DaemonToolSyncItem {
  final String toolId;
  final String alias;
  final String status;
  final String endpoint;
  final DateTime updatedAt;

  const DaemonToolSyncItem({
    required this.toolId,
    required this.alias,
    required this.status,
    required this.endpoint,
    required this.updatedAt,
  });
}

class DaemonToolSyncSnapshot {
  final bool running;
  final String host;
  final int port;
  final int revision;
  final List<DaemonToolSyncItem> activeTools;

  const DaemonToolSyncSnapshot({
    required this.running,
    required this.host,
    required this.port,
    required this.revision,
    required this.activeTools,
  });
}
