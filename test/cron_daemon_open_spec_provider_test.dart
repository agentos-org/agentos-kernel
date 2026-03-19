import 'dart:convert';

import 'package:agentos_kernel/src/kernel/cron/daemon_open_spec_provider.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_daemon/opentool_daemon_client.dart';
import 'package:opentool_dart/opentool_schema.dart';
import 'package:test/test.dart';

void main() {
  group('CronDaemonOpenSpecProvider', () {
    test('refreshes daemon tools after cache ttl expires', () async {
      var now = DateTime(2026, 1, 1, 0, 0, 0);
      var listCalls = 0;
      final toolSpecs = <String, OpenTool>{
        'tool-a': _buildTool('Tool A', 'search_a'),
        'tool-b': _buildTool('Tool B', 'search_b'),
      };
      var currentTools = <ToolWithApiKeyDto>[
        _toolInfo(id: 'tool-a', status: 'running'),
      ];
      final provider = CronDaemonOpenSpecProvider(
        host: '127.0.0.1',
        port: 8080,
        daemonApiKey: 'daemon-key',
        cacheTtl: const Duration(seconds: 2),
        now: () => now,
        listTools:
            ({
              required String host,
              required int port,
              required String daemonApiKey,
            }) async {
              listCalls += 1;
              return List<ToolWithApiKeyDto>.from(currentTools);
            },
        loadTool:
            ({
              required String host,
              required int port,
              required String toolId,
            }) async => toolSpecs[toolId],
        mapToOpenSpec: _mapToOpenSpec,
      );

      final first = await provider.resolveOpenSpecs();
      currentTools = <ToolWithApiKeyDto>[
        _toolInfo(id: 'tool-b', status: 'running'),
      ];
      final second = await provider.resolveOpenSpecs();
      now = now.add(const Duration(seconds: 3));
      final third = await provider.resolveOpenSpecs();

      expect(listCalls, 2);
      expect(first.map(_toolTitleFromOpenSpec), ['Tool A']);
      expect(second.map(_toolTitleFromOpenSpec), ['Tool A']);
      expect(third.map(_toolTitleFromOpenSpec), ['Tool B']);
    });

    test('falls back to cached specs when daemon refresh fails', () async {
      var now = DateTime(2026, 1, 1, 0, 0, 0);
      var shouldFail = false;
      final provider = CronDaemonOpenSpecProvider(
        host: '127.0.0.1',
        port: 8080,
        daemonApiKey: 'daemon-key',
        cacheTtl: const Duration(seconds: 1),
        now: () => now,
        listTools:
            ({
              required String host,
              required int port,
              required String daemonApiKey,
            }) async {
              if (shouldFail) {
                throw StateError('daemon unavailable');
              }
              return <ToolWithApiKeyDto>[
                _toolInfo(id: 'tool-a', status: 'running'),
              ];
            },
        loadTool:
            ({
              required String host,
              required int port,
              required String toolId,
            }) async => _buildTool('Tool A', 'search_a'),
        mapToOpenSpec: _mapToOpenSpec,
      );

      final first = await provider.resolveOpenSpecs();
      shouldFail = true;
      now = now.add(const Duration(seconds: 2));
      final second = await provider.resolveOpenSpecs();

      expect(first.map(_toolTitleFromOpenSpec), ['Tool A']);
      expect(second.map(_toolTitleFromOpenSpec), ['Tool A']);
    });
  });
}

ToolWithApiKeyDto _toolInfo({required String id, required String status}) {
  return ToolWithApiKeyDto(
    id: id,
    alias: id,
    host: '127.0.0.1',
    port: 9090,
    apiKey: 'tool-key',
    status: status,
  );
}

OpenTool _buildTool(String title, String functionName) {
  return OpenTool(
    opentool: '1.1.0',
    info: Info(
      title: title,
      description: '$title description',
      version: '1.0.0',
    ),
    functions: [
      FunctionModel(
        name: functionName,
        description: '$functionName description',
        parameters: const [],
      ),
    ],
  );
}

OpenSpec _mapToOpenSpec(ToolWithApiKeyDto toolInfo, OpenTool spec) {
  return OpenSpec(
    openSpec: jsonEncode(spec.toJson()),
    protocol: Protocol.opentool,
    serverUrl: 'http://${toolInfo.host}:${toolInfo.port}',
  );
}

String _toolTitleFromOpenSpec(OpenSpec spec) {
  final decoded = jsonDecode(spec.openSpec) as Map<String, dynamic>;
  final info = decoded['info'] as Map<String, dynamic>;
  return info['title'] as String;
}
