import 'dart:convert';
import 'dart:io';

import 'package:agentos_kernel/src/kernel/kernel.dart';
import 'package:agentos_kernel/src/kernel/memory/drift_memory.dart';
import 'package:agentos_kernel/src/kernel/memory/memory_pipeline.dart';
import 'package:agentos_kernel/src/kernel/opentool/opentool_daemon_registry.dart';
import 'package:agentos_kernel/src/kernel/preference/preference.dart';
import 'package:agentos_kernel/src/kernel/preference/preference_extractor.dart';
import 'package:agentos_kernel/src/kernel/preference/vector_store.dart';
import 'package:agentos_kernel/src/kernel/rag/drift_rag.dart';
import 'package:agentos_kernel/src/kernel/rag/rag.dart';
import 'package:agentos_kernel/src/kernel/supervision/supervision.dart';
import 'package:agentos_kernel/src/service/kernel_service.dart';
import 'package:test/test.dart';

void main() {
  group('KernelService embeddings configuration', () {
    test('keeps local model configuration behavior', () async {
      final server = await _FakeEmbeddingsServer.start();
      final harness = await _TestHarness.create();
      addTearDown(server.close);
      addTearDown(harness.dispose);

      final configured = await harness.service.updateEmbeddingsConfig(
        EmbeddingsConfig(
          baseUrl: server.baseUrl,
          apiKey: 'local-key',
          docsName: 'local-docs',
          model: 'local-model',
        ),
      );

      expect(configured, isTrue);
      final request = server.createDocsRequest;
      expect(request.authorization, 'Bearer local-key');
      expect(request.llmConfig['baseUrl'], server.baseUrl);
      expect(request.llmConfig['apiKey'], 'local-key');
      expect(request.llmConfig['model'], 'local-model');
    });

    test('uses the remote embedding model base URL', () async {
      final server = await _FakeEmbeddingsServer.start();
      final harness = await _TestHarness.create();
      addTearDown(server.close);
      addTearDown(harness.dispose);

      final configured = await harness.service.updateEmbeddingsConfig(
        EmbeddingsConfig(
          baseUrl: server.baseUrl,
          embeddingModelBaseUrl: 'https://embedding.example/v1',
          apiKey: 'shared-key',
          docsName: 'remote-docs',
          model: 'remote-model',
        ),
      );

      expect(configured, isTrue);
      expect(
        server.createDocsRequest.llmConfig['baseUrl'],
        'https://embedding.example/v1',
      );
    });

    test('separates vector store and embedding model API keys', () async {
      final server = await _FakeEmbeddingsServer.start();
      final harness = await _TestHarness.create();
      addTearDown(server.close);
      addTearDown(harness.dispose);

      final configured = await harness.service.updateEmbeddingsConfig(
        EmbeddingsConfig(
          baseUrl: server.baseUrl,
          embeddingModelBaseUrl: 'https://embedding.example/v1',
          apiKey: 'vector-store-key',
          embeddingModelApiKey: 'embedding-model-key',
          docsName: 'separate-keys-docs',
          model: 'remote-model',
        ),
      );

      expect(configured, isTrue);
      final request = server.createDocsRequest;
      expect(request.authorization, 'Bearer vector-store-key');
      expect(request.llmConfig['apiKey'], 'embedding-model-key');
    });

    test('falls back to apiKey when embeddingModelApiKey is absent', () async {
      final server = await _FakeEmbeddingsServer.start();
      final harness = await _TestHarness.create();
      addTearDown(server.close);
      addTearDown(harness.dispose);

      final configured = await harness.service.updateEmbeddingsConfig(
        EmbeddingsConfig(
          baseUrl: server.baseUrl,
          embeddingModelBaseUrl: 'https://embedding.example/v1',
          apiKey: 'legacy-key',
          docsName: 'legacy-docs',
          model: 'remote-model',
        ),
      );

      expect(configured, isTrue);
      expect(server.createDocsRequest.llmConfig['apiKey'], 'legacy-key');
    });

    test('leaves embeddings unconfigured when model is blank', () async {
      final server = await _FakeEmbeddingsServer.start();
      final harness = await _TestHarness.create();
      addTearDown(server.close);
      addTearDown(harness.dispose);

      final configured = await harness.service.updateEmbeddingsConfig(
        EmbeddingsConfig(
          baseUrl: server.baseUrl,
          apiKey: 'vector-store-key',
          embeddingModelApiKey: 'embedding-model-key',
          docsName: 'blank-model-docs',
          model: '   ',
        ),
      );

      expect(configured, isFalse);
      expect(server.requests, isEmpty);
    });
  });
}

class _TestHarness {
  final Directory tempDir;
  final KernelService service;

  const _TestHarness({required this.tempDir, required this.service});

  static Future<_TestHarness> create() async {
    final tempDir = await Directory.systemTemp.createTemp(
      'kernel-embeddings-config-test-',
    );
    final memory = DriftMemory.open(path: '${tempDir.path}/memory.sqlite');
    final ragStore = DriftRag.open(path: '${tempDir.path}/rag.sqlite');
    final kernel = Kernel(
      openToolDaemonRegistry: OpenToolDaemonRegistry(),
      supervision: PassiveSupervision(),
      memory: memory,
      memoryPipeline: MemoryPipeline(memory: memory),
      preference: InMemoryPreference(),
      preferenceExtractor: OfflinePreferenceExtractor(),
      rag: Rag(store: ragStore),
    );
    final service = KernelService(
      kernel,
      preferenceVectorStore: SwitchableTextQueryVectorStore(
        ThrowingTextQueryVectorStore(),
      ),
    );
    return _TestHarness(tempDir: tempDir, service: service);
  }

  Future<void> dispose() => tempDir.delete(recursive: true);
}

class _FakeEmbeddingsServer {
  final HttpServer _server;
  final List<_CapturedRequest> requests = [];

  _FakeEmbeddingsServer._(this._server) {
    _server.listen(_handleRequest);
  }

  static Future<_FakeEmbeddingsServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeEmbeddingsServer._(server);
  }

  String get baseUrl => 'http://${_server.address.address}:${_server.port}';

  _CapturedRequest get createDocsRequest =>
      requests.singleWhere((request) => request.path == '/api/docs/create');

  Future<void> close() => _server.close(force: true);

  Future<void> _handleRequest(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final decodedBody = body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;
    requests.add(
      _CapturedRequest(
        path: request.uri.path,
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
        body: decodedBody,
      ),
    );

    request.response.headers.contentType = ContentType.json;
    if (request.method == 'GET' && request.uri.path == '/api/docs/list') {
      request.response.write('[]');
    } else if (request.method == 'POST' &&
        request.uri.path == '/api/docs/create') {
      request.response.write(
        jsonEncode({
          'docsId': 'docs-1',
          'docsName': decodedBody['docsName'],
          'tokenUsage': {'promptToken': 1, 'totalToken': 1},
        }),
      );
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'not found'}));
    }
    await request.response.close();
  }
}

class _CapturedRequest {
  final String path;
  final String? authorization;
  final Map<String, dynamic> body;

  const _CapturedRequest({
    required this.path,
    required this.authorization,
    required this.body,
  });

  Map<String, dynamic> get llmConfig =>
      body['llmConfig'] as Map<String, dynamic>;
}
