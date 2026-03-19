import 'dart:async';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_daemon/opentool_daemon_client.dart';
import 'package:opentool_dart/opentool_schema.dart';

import '../logging/logger.dart';

typedef CronDaemonToolListLoader =
    Future<List<ToolWithApiKeyDto>> Function({
      required String host,
      required int port,
      required String daemonApiKey,
    });

typedef CronDaemonToolSpecLoader =
    Future<OpenTool?> Function({
      required String host,
      required int port,
      required String toolId,
    });

typedef CronDaemonOpenSpecMapper =
    OpenSpec Function(ToolWithApiKeyDto toolInfo, OpenTool spec);

class CronDaemonOpenSpecProvider {
  String host;
  int port;
  String? daemonApiKey;
  final Duration cacheTtl;
  final KernelLogger? logger;
  final DateTime Function() _now;
  final CronDaemonToolListLoader _listTools;
  final CronDaemonToolSpecLoader _loadTool;
  final CronDaemonOpenSpecMapper _mapToOpenSpec;

  List<OpenSpec> _cachedOpenSpecs = const <OpenSpec>[];
  DateTime? _cachedAt;
  Future<List<OpenSpec>>? _inFlight;

  CronDaemonOpenSpecProvider({
    required this.host,
    required this.port,
    required CronDaemonOpenSpecMapper mapToOpenSpec,
    this.daemonApiKey,
    this.cacheTtl = const Duration(seconds: 2),
    this.logger,
    DateTime Function()? now,
    CronDaemonToolListLoader? listTools,
    CronDaemonToolSpecLoader? loadTool,
  }) : _now = now ?? DateTime.now,
       _listTools = listTools ?? _defaultListTools,
       _loadTool = loadTool ?? _defaultLoadTool,
       _mapToOpenSpec = mapToOpenSpec;

  Future<List<OpenSpec>> resolveOpenSpecs() async {
    final apiKey = daemonApiKey?.trim();
    if (apiKey == null || apiKey.isEmpty) {
      return const <OpenSpec>[];
    }
    final cached = _resolveCached();
    if (cached != null) {
      return cached;
    }
    final inFlight = _inFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _refreshOpenSpecs(apiKey);
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  List<OpenSpec>? _resolveCached() {
    final cachedAt = _cachedAt;
    if (cachedAt == null) {
      return null;
    }
    if (_now().difference(cachedAt) > cacheTtl) {
      return null;
    }
    return List<OpenSpec>.unmodifiable(_cachedOpenSpecs);
  }

  Future<List<OpenSpec>> _refreshOpenSpecs(String apiKey) async {
    try {
      final toolList = await _listTools(
        host: host,
        port: port,
        daemonApiKey: apiKey,
      );
      final openSpecs = <OpenSpec>[];
      for (final toolInfo in toolList) {
        if (toolInfo.status != 'running') {
          continue;
        }
        final spec = await _loadTool(
          host: host,
          port: port,
          toolId: toolInfo.id,
        );
        if (spec == null) {
          continue;
        }
        openSpecs.add(_mapToOpenSpec(toolInfo, spec));
      }
      _cachedOpenSpecs = List<OpenSpec>.unmodifiable(openSpecs);
      _cachedAt = _now();
      return _cachedOpenSpecs;
    } catch (error, stackTrace) {
      if (_cachedAt != null) {
        logger?.warn(
          'Failed to refresh cron daemon OpenTool specs. Using cached specs.',
          data: {
            'host': host,
            'port': port,
            'error': error.toString(),
            'stackTrace': stackTrace.toString(),
          },
        );
        return List<OpenSpec>.unmodifiable(_cachedOpenSpecs);
      }
      rethrow;
    }
  }

  static Future<List<ToolWithApiKeyDto>> _defaultListTools({
    required String host,
    required int port,
    required String daemonApiKey,
  }) {
    final client = DaemonClient(host: host, port: port);
    return client.listToolWithApiKeys('1', daemonApiKey: daemonApiKey);
  }

  static Future<OpenTool?> _defaultLoadTool({
    required String host,
    required int port,
    required String toolId,
  }) {
    final client = DaemonClient(host: host, port: port);
    return client.loadTool(toolId);
  }
}
