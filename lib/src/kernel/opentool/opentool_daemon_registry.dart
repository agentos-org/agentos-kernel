import 'package:opentool_dart/opentool_schema.dart';

class OpenToolDaemonRegistry {
  final Map<String, OpenTool> _byId = {};
  final Map<String, int> _titleCounts = {};

  String registerRemote(
    OpenTool tool, {
    String? toolId,
    String? serverUrl,
    String? apiKey,
  }) {
    final id = _resolveToolId(tool, toolId);
    _byId[id] = tool;
    return id;
  }

  bool unregister(String toolId) {
    return _byId.remove(toolId) != null;
  }

  String _resolveToolId(OpenTool tool, String? toolId) {
    if (toolId != null && toolId.trim().isNotEmpty) {
      return toolId.trim();
    }
    final rawTitle = tool.info.title.trim();
    final base = rawTitle.isEmpty ? 'tool_${_byId.length}' : rawTitle;
    final count = _titleCounts[base] ?? 0;
    _titleCounts[base] = count + 1;
    if (count == 0) {
      return base;
    }
    return '$base#$count';
  }
}
