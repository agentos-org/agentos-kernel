import 'package:agentos_kernel/src/kernel/cron/daemon_open_spec_provider.dart';
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
      var currentTools = <ToolDto>[_toolInfo(id: 'tool-a', status: 'running')];
      final provider = CronDaemonOpenSpecProvider(
        host: '127.0.0.1',
        port: 8080,
        cacheTtl: const Duration(seconds: 2),
        now: () => now,
        listTools: ({required String host, required int port}) async {
          listCalls += 1;
          return List<ToolDto>.from(currentTools);
        },
        loadTool:
            ({
              required String host,
              required int port,
              required String toolId,
            }) async => toolSpecs[toolId],
      );

      final first = await provider.resolveCatalog();
      currentTools = <ToolDto>[_toolInfo(id: 'tool-b', status: 'running')];
      final second = await provider.resolveCatalog();
      now = now.add(const Duration(seconds: 3));
      final third = await provider.resolveCatalog();

      expect(listCalls, 2);
      expect(first.map((item) => item.spec.info.title), ['Tool A']);
      expect(second.map((item) => item.spec.info.title), ['Tool A']);
      expect(third.map((item) => item.spec.info.title), ['Tool B']);
    });

    test('falls back to cached catalog when daemon refresh fails', () async {
      var now = DateTime(2026, 1, 1, 0, 0, 0);
      var shouldFail = false;
      final provider = CronDaemonOpenSpecProvider(
        host: '127.0.0.1',
        port: 8080,
        cacheTtl: const Duration(seconds: 1),
        now: () => now,
        listTools: ({required String host, required int port}) async {
          if (shouldFail) {
            throw StateError('daemon unavailable');
          }
          return <ToolDto>[_toolInfo(id: 'tool-a', status: 'running')];
        },
        loadTool:
            ({
              required String host,
              required int port,
              required String toolId,
            }) async => _buildTool('Tool A', 'search_a'),
      );

      final first = await provider.resolveCatalog();
      shouldFail = true;
      now = now.add(const Duration(seconds: 2));
      final second = await provider.resolveCatalog();

      expect(first.map((item) => item.spec.info.title), ['Tool A']);
      expect(second.map((item) => item.spec.info.title), ['Tool A']);
    });

    test('skips a single running tool when loading its spec fails', () async {
      final provider = CronDaemonOpenSpecProvider(
        host: '127.0.0.1',
        port: 8080,
        listTools: ({required String host, required int port}) async => [
          _toolInfo(id: 'tool-a', status: 'running'),
          _toolInfo(id: 'tool-b', status: 'running'),
        ],
        loadTool:
            ({
              required String host,
              required int port,
              required String toolId,
            }) async {
              if (toolId == 'tool-b') {
                throw StateError('404');
              }
              return _buildTool('Tool A', 'search_a');
            },
      );

      final catalog = await provider.resolveCatalog();

      expect(catalog, hasLength(1));
      expect(catalog.single.toolId, 'tool-a');
      expect(catalog.single.spec.info.title, 'Tool A');
    });
  });
}

ToolDto _toolInfo({required String id, required String status}) {
  return ToolDto(
    id: id,
    alias: id,
    host: '127.0.0.1',
    port: 9090,
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
