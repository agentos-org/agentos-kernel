import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_dart/opentool_client.dart' as ot;
import 'package:opentool_dart/opentool_schema.dart';

class AppInfo {
  final String bundleId;
  final String version;
  final String description;
  final String name;

  const AppInfo({
    required this.bundleId,
    required this.version,
    required this.description,
    required this.name,
  });

  Map<String, dynamic> toJson() => {
        'bundleId': bundleId,
        'version': version,
        'description': description,
        'name': name,
      };
}

class AppCallResult {
  final bool success;
  final String? message;

  const AppCallResult.success() : success = true, message = null;

  const AppCallResult.failure(this.message) : success = false;

  Map<String, dynamic> toJson() => {
        'status': success ? 'ok' : 'error',
        if (message != null) 'message': message,
      };
}

abstract class AppCalledHandler {
  Future<AppCallResult> callApp({
    required String bundleId,
    required List<Content> contentList,
  });
}

class AppCalledTool implements ot.Tool {
  static const String toolId = 'AppCaller';
  static const String _functionName = 'callApp';

  final List<AppInfo> _apps = [];
  AppCalledHandler? _handler;

  void updateApps(List<AppInfo> apps) {
    _apps
      ..clear()
      ..addAll(apps);
  }

  void updateHandler(AppCalledHandler handler) {
    _handler = handler;
  }

  OpenTool buildSpec() {
    final bundleIds = _apps.map((app) => app.bundleId).toList();
    final bundleDescriptions = _apps
        .map((app) => '${app.bundleId} - ${app.description}')
        .join('; ');
    return OpenTool(
      opentool: '1.1.0',
      info: Info(
        title: 'Kernel App Tools',
        description: 'Call external apps by bundleId.',
        version: '1.0.0',
      ),
      functions: [
        FunctionModel(
          name: _functionName,
          description: 'Call an external app by bundleId.',
          parameters: [
            Parameter(
              name: 'bundleId',
              description: bundleDescriptions.isEmpty ? null : bundleDescriptions,
              required: true,
              schema: Schema(
                type: SchemaType.STRING,
                enum_: bundleIds,
              ),
            ),
            Parameter(
              name: 'contentList',
              description: 'LiteAgent content list.',
              required: true,
              schema: Schema(
                type: SchemaType.ARRAY,
                items: Schema(
                  type: SchemaType.OBJECT,
                  properties: const {},
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic>? arguments,
  ) async {
    if (name != _functionName) {
      return ot.FunctionNotSupportedException(functionName: name).toJson();
    }
    if (arguments == null) {
      return const {'status': 'error', 'message': 'Missing arguments.'};
    }
    final bundleId = arguments['bundleId'];
    final contentRaw = arguments['contentList'];
    if (bundleId is! String || bundleId.trim().isEmpty) {
      return const {'status': 'error', 'message': 'Invalid bundleId.'};
    }
    if (contentRaw is! List) {
      return const {'status': 'error', 'message': 'Invalid contentList.'};
    }
    final handler = _handler;
    if (handler == null) {
      return const {'status': 'error', 'message': 'App handler not configured.'};
    }
    try {
      final contentList = contentRaw.map((item) {
        if (item is Content) {
          return item;
        }
        if (item is Map) {
          return Content.fromJson(Map<String, dynamic>.from(item));
        }
        final decoded = jsonDecode(item.toString());
        if (decoded is Map) {
          return Content.fromJson(Map<String, dynamic>.from(decoded));
        }
        throw const FormatException('Invalid content item.');
      }).toList();
      final result = await handler.callApp(
        bundleId: bundleId,
        contentList: contentList,
      );
      return result.toJson();
    } catch (error) {
      return {
        'status': 'error',
        'message': 'App call failed: $error',
      };
    }
  }

  @override
  Future<OpenTool?> load() async => buildSpec();

  @override
  Future<void> dispose() async {}

  @override
  Future<void> init() async {}

  @override
  Future<void> streamCall(String name, Map<String, dynamic>? arguments, void Function(String event, Map<String, dynamic> data) onEvent) async {
    onEvent(ot.EventType.ERROR, ot.FunctionNotSupportedException(functionName: name).toJson());
  }
}
