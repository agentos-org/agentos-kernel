import 'dart:async';
import 'dart:convert';

import 'package:opentool_daemon/opentool_daemon_client.dart';
import 'package:opentool_dart/opentool_schema.dart';

import '../logging/logger.dart';

typedef CronDaemonToolListLoader =
    Future<List<ToolDto>> Function({required String host, required int port});

typedef CronDaemonToolSpecLoader =
    Future<OpenTool?> Function({
      required String host,
      required int port,
      required String toolId,
    });

class CronDaemonToolCatalogItem {
  final String toolId;
  final String alias;
  final String status;
  final String? serverId;
  final OpenTool spec;

  const CronDaemonToolCatalogItem({
    required this.toolId,
    required this.alias,
    required this.status,
    required this.spec,
    this.serverId,
  });

  Map<String, dynamic> toJson() {
    return {
      'toolId': toolId,
      'alias': alias,
      'status': status,
      'serverId': serverId,
      'spec': spec.toJson(),
    };
  }
}

class CronDaemonOpenSpecProvider {
  String host;
  int port;
  final Duration cacheTtl;
  final KernelLogger? logger;
  final DateTime Function() _now;
  final CronDaemonToolListLoader _listTools;
  final CronDaemonToolSpecLoader _loadTool;

  List<CronDaemonToolCatalogItem> _cachedCatalog =
      const <CronDaemonToolCatalogItem>[];
  DateTime? _cachedAt;
  Future<List<CronDaemonToolCatalogItem>>? _inFlight;

  CronDaemonOpenSpecProvider({
    required this.host,
    required this.port,
    this.cacheTtl = const Duration(seconds: 2),
    this.logger,
    DateTime Function()? now,
    CronDaemonToolListLoader? listTools,
    CronDaemonToolSpecLoader? loadTool,
  }) : _now = now ?? DateTime.now,
       _listTools = listTools ?? _defaultListTools,
       _loadTool = loadTool ?? _defaultLoadTool;

  Future<List<CronDaemonToolCatalogItem>> resolveCatalog() async {
    final cached = _resolveCached();
    if (cached != null) {
      _debugPrint('resolve_cache_hit', {
        'host': host,
        'port': port,
        'toolCount': cached.length,
      });
      return cached;
    }
    final inFlight = _inFlight;
    if (inFlight != null) {
      _debugPrint('resolve_join_inflight', {'host': host, 'port': port});
      return inFlight;
    }
    _debugPrint('resolve_refresh_start', {'host': host, 'port': port});
    final future = _refreshCatalog();
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  List<CronDaemonToolCatalogItem>? _resolveCached() {
    final cachedAt = _cachedAt;
    if (cachedAt == null) {
      return null;
    }
    if (_now().difference(cachedAt) > cacheTtl) {
      return null;
    }
    return List<CronDaemonToolCatalogItem>.unmodifiable(_cachedCatalog);
  }

  Future<List<CronDaemonToolCatalogItem>> _refreshCatalog() async {
    try {
      final toolList = await _listTools(host: host, port: port);
      _debugPrint('refresh_list_tools_done', {
        'host': host,
        'port': port,
        'toolCount': toolList.length,
        'tools': toolList
            .map(
              (tool) => {
                'id': tool.id,
                'alias': tool.alias,
                'status': tool.status,
                'serverId': tool.serverId,
              },
            )
            .toList(growable: false),
      });
      final catalog = <CronDaemonToolCatalogItem>[];
      for (final toolInfo in toolList) {
        if (toolInfo.status != 'running') {
          _debugPrint('refresh_skip_tool_not_running', {
            'toolId': toolInfo.id,
            'alias': toolInfo.alias,
            'status': toolInfo.status,
          });
          continue;
        }
        try {
          final spec = await _loadTool(
            host: host,
            port: port,
            toolId: toolInfo.id,
          );
          if (spec == null) {
            _debugPrint('refresh_skip_tool_spec_missing', {
              'toolId': toolInfo.id,
              'alias': toolInfo.alias,
            });
            continue;
          }
          _debugPrint('refresh_tool_spec_loaded', {
            'toolId': toolInfo.id,
            'alias': toolInfo.alias,
          });
          catalog.add(
            CronDaemonToolCatalogItem(
              toolId: toolInfo.id,
              alias: toolInfo.alias,
              status: toolInfo.status,
              serverId: toolInfo.serverId,
              spec: spec,
            ),
          );
        } catch (error, stackTrace) {
          _debugPrint('refresh_skip_tool_spec_load_failed', {
            'toolId': toolInfo.id,
            'alias': toolInfo.alias,
            'error': error.toString(),
          });
          logger?.warn(
            'Failed to load cron daemon tool spec. Skipping tool.',
            data: {
              'host': host,
              'port': port,
              'toolId': toolInfo.id,
              'alias': toolInfo.alias,
              'error': error.toString(),
              'stackTrace': stackTrace.toString(),
            },
          );
          continue;
        }
      }
      _cachedCatalog = List<CronDaemonToolCatalogItem>.unmodifiable(catalog);
      _cachedAt = _now();
      _debugPrint('refresh_completed', {
        'host': host,
        'port': port,
        'toolCount': _cachedCatalog.length,
        'tools': _cachedCatalog.map((item) => item.toJson()).toList(),
      });
      return _cachedCatalog;
    } catch (error, stackTrace) {
      _debugPrint('refresh_failed', {
        'host': host,
        'port': port,
        'error': error.toString(),
      });
      if (_cachedAt != null) {
        logger?.warn(
          'Failed to refresh cron daemon tool catalog. Using cached tools.',
          data: {
            'host': host,
            'port': port,
            'error': error.toString(),
            'stackTrace': stackTrace.toString(),
          },
        );
        return List<CronDaemonToolCatalogItem>.unmodifiable(_cachedCatalog);
      }
      rethrow;
    }
  }

  static Future<List<ToolDto>> _defaultListTools({
    required String host,
    required int port,
  }) {
    final client = DaemonClient(host: host, port: port);
    return client.listTool('1');
  }

  static Future<OpenTool?> _defaultLoadTool({
    required String host,
    required int port,
    required String toolId,
  }) {
    final client = DaemonClient(host: host, port: port);
    return client.loadTool(toolId);
  }

  void _debugPrint(String stage, Map<String, dynamic> data) {
    print(
      jsonEncode({
        'tag': 'cron_daemon_open_spec_provider',
        'stage': stage,
        'timestamp': DateTime.now().toIso8601String(),
        'data': data,
      }),
    );
  }
}
