import 'dart:async';

import 'package:opentool_dart/opentool_client.dart' as ot;
import 'package:opentool_dart/opentool_schema.dart';

class OpenToolDirectory {
  final Map<String, OpenTool> _byId = {};
  final Map<String, ot.Tool> _localHandlers = {};
  final Map<String, String?> _apiKeys = {};
  final Map<String, String> _serverUrls = {};
  final Map<String, ot.OpenToolClient> _clients = {};
  final Map<String, String> _functionToToolId = {};
  final Map<String, int> _titleCounts = {};
  final List<_LocalToolEntry> _localTools = [];

  Iterable<OpenTool> get tools => _byId.values;

  bool get isEmpty => _byId.isEmpty && _localTools.isEmpty;

  void registerLocal(ot.Tool handler, {String? toolId}) {
    _localTools.add(_LocalToolEntry(handler: handler, preferredId: toolId));
  }

  void updateLocalToolSpec(ot.Tool handler, OpenTool spec, {String? toolId}) {
    _LocalToolEntry? entry;
    for (final item in _localTools) {
      if (item.handler == handler) {
        entry = item;
        break;
      }
    }
    if (entry == null) {
      registerLocal(handler, toolId: toolId);
      entry = _localTools.last;
    }
    final resolvedId =
        toolId ?? entry.preferredId ?? _resolveToolId(spec, entry.preferredId);
    if (entry.toolId != null && entry.toolId != resolvedId) {
      _byId.remove(entry.toolId);
      _localHandlers.remove(entry.toolId);
      _removeFunctionMappingsForTool(entry.toolId!);
    }
    entry.spec = spec;
    entry.toolId = resolvedId;
    _byId[resolvedId] = spec;
    _localHandlers[resolvedId] = handler;
    _removeFunctionMappingsForTool(resolvedId);
    _indexFunctions(resolvedId, spec.functions);
  }

  String registerRemote(
    OpenTool tool, {
    String? toolId,
    String? serverUrl,
    String? apiKey,
  }) {
    final id = _resolveToolId(tool, toolId);
    _removeFunctionMappingsForTool(id);
    _byId[id] = tool;
    final url = serverUrl ?? tool.server?.url;
    if (url != null && url.isNotEmpty) {
      _serverUrls[id] = url;
    }
    if (apiKey != null && apiKey.isNotEmpty) {
      _apiKeys[id] = apiKey;
    }
    _indexFunctions(id, tool.functions);
    return id;
  }

  bool unregister(String toolId) {
    final local = _localHandlers.remove(toolId);
    if (local != null) {
      return false;
    }
    final removed = _byId.remove(toolId);
    _apiKeys.remove(toolId);
    _serverUrls.remove(toolId);
    _clients.remove(toolId);
    _removeFunctionMappingsForTool(toolId);
    return removed != null;
  }

  bool updateRemoteEndpoint(
    String toolId, {
    String? serverUrl,
    String? apiKey,
  }) {
    if (!_byId.containsKey(toolId)) {
      return false;
    }
    if (serverUrl != null && serverUrl.trim().isNotEmpty) {
      _serverUrls[toolId] = serverUrl.trim();
    }
    if (apiKey != null) {
      final trimmed = apiKey.trim();
      if (trimmed.isEmpty) {
        _apiKeys.remove(toolId);
      } else {
        _apiKeys[toolId] = trimmed;
      }
    }
    _clients.remove(toolId);
    return true;
  }

  OpenTool? byId(String id) => _byId[id];

  String? resolveToolIdForFunction(String functionName) {
    return _functionToToolId[functionName];
  }

  Future<List<Map<String, dynamic>>> summaries() async {
    await ensureLoaded();
    final summaries = <Map<String, dynamic>>[];
    _byId.forEach((id, tool) {
      summaries.add({
        'id': id,
        'title': tool.info.title,
        'description': tool.info.description,
        'version': tool.info.version,
        'serverUrl': _serverUrls[id] ?? tool.server?.url,
        'functions': tool.functions
            .map(
              (function) => {
                'name': function.name,
                'description': function.description,
                'parameters': function.parameters
                    .map(
                      (param) => {
                        'name': param.name,
                        'required': param.required,
                        'description': param.description,
                        'schema': param.schema.toJson(),
                      },
                    )
                    .toList(),
              },
            )
            .toList(),
      });
    });
    return summaries;
  }

  Future<ot.ToolReturn> call({
    required String toolId,
    required String function,
    required Map<String, dynamic> arguments,
    String? callId,
  }) async {
    if (!_byId.containsKey(toolId) && _localTools.isNotEmpty) {
      await ensureLoaded();
    }
    final local = _localHandlers[toolId];
    if (local != null) {
      final result = await local.call(function, arguments);
      return ot.ToolReturn(id: callId ?? _callId(), result: result);
    }
    final url = _serverUrls[toolId] ?? _byId[toolId]?.server?.url;
    if (url == null || url.isEmpty) {
      throw StateError('OpenTool server url missing for $toolId');
    }
    final client = _clientFor(toolId, url);
    final functionCall = ot.FunctionCall(
      id: callId ?? _callId(),
      name: function,
      arguments: arguments,
    );
    return client.call(functionCall);
  }

  Future<void> ensureLoaded() async {
    if (_localTools.isEmpty) {
      return;
    }
    final futures = <Future<void>>[];
    for (final entry in _localTools) {
      if (entry.spec != null) {
        continue;
      }
      entry.loading ??= entry.handler.load();
      futures.add(_loadEntry(entry));
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  Future<void> _loadEntry(_LocalToolEntry entry) async {
    final spec = await entry.loading;
    if (spec == null) {
      return;
    }
    entry.spec = spec;
    final id = _resolveToolId(spec, entry.preferredId);
    entry.toolId = id;
    _byId[id] = spec;
    _localHandlers[id] = entry.handler;
    _indexFunctions(id, spec.functions);
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

  void _indexFunctions(String toolId, List<FunctionModel> functions) {
    for (final function in functions) {
      _functionToToolId.putIfAbsent(function.name, () => toolId);
    }
  }

  void _removeFunctionMappingsForTool(String toolId) {
    final keys = _functionToToolId.entries
        .where((entry) => entry.value == toolId)
        .map((entry) => entry.key)
        .toList();
    for (final key in keys) {
      _functionToToolId.remove(key);
    }
  }

  ot.OpenToolClient _clientFor(String toolId, String url) {
    final existing = _clients[toolId];
    if (existing != null) {
      return existing;
    }
    final uri = Uri.parse(url);
    final host = uri.host.isNotEmpty ? uri.host : uri.path;
    final isSSL = uri.scheme == 'https';
    final port = uri.hasPort ? uri.port : (isSSL ? 443 : 80);
    final client = ot.OpenToolClient(
      isSSL: isSSL,
      toolHost: host,
      toolPort: port,
      toolApiKey: _apiKeys[toolId],
    );
    _clients[toolId] = client;
    return client;
  }

  String _callId() => 'call-${DateTime.now().microsecondsSinceEpoch}';
}

class _LocalToolEntry {
  final ot.Tool handler;
  final String? preferredId;
  String? toolId;
  OpenTool? spec;
  Future<OpenTool?>? loading;

  _LocalToolEntry({required this.handler, this.preferredId});
}
