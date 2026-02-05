import 'dart:async';

import 'package:opentool_dart/opentool_client.dart';

class MockCrudTool extends Tool {
  final List<String> _storage;

  MockCrudTool({List<String>? seed})
      : _storage = List<String>.from(seed ?? const []);

  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic>? arguments,
  ) async {
    final args = arguments ?? const {};
    switch (name) {
      case 'count':
        return {
          'count': _storage.length,
          'message': 'Counted ${_storage.length} records.',
        };
      case 'create':
        final text = args['text'] as String?;
        if (text == null || text.isEmpty) {
          return {'error': 'Missing text for create.'};
        }
        _storage.add(text);
        return {
          'id': _storage.length - 1,
          'message': 'Created record.',
        };
      case 'read':
        final id = _parseId(args['id']);
        if (id == null || id < 0 || id >= _storage.length) {
          return {'error': 'Invalid id for read.'};
        }
        return {
          'id': id,
          'text': _storage[id],
          'message': 'Read record.',
        };
      case 'list':
        return {
          'items': List<String>.from(_storage),
          'message': 'Listed records.',
        };
      case 'sequentiallyRead':
        final results = <String>[];
        for (final item in _storage) {
          results.add(item);
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        return {
          'items': results,
          'message': 'Sequential read complete.',
        };
      case 'update':
        final id = _parseId(args['id']);
        final text = args['text'] as String?;
        if (id == null || id < 0 || id >= _storage.length) {
          return {'error': 'Invalid id for update.'};
        }
        if (text == null || text.isEmpty) {
          return {'error': 'Missing text for update.'};
        }
        _storage[id] = text;
        return {
          'id': id,
          'text': text,
          'message': 'Updated record.',
        };
      case 'delete':
        final id = _parseId(args['id']);
        if (id == null || id < 0 || id >= _storage.length) {
          return {'error': 'Invalid id for delete.'};
        }
        _storage.removeAt(id);
        return {
          'id': id,
          'message': 'Deleted record.',
        };
      case 'run':
        throw StateError('Mock tool triggered fatal error.');
      default:
        return {'error': 'Unknown action: $name'};
    }
  }

  @override
  Future<OpenTool?> load() async {
    return _buildOpenTool();
  }

  int? _parseId(Object? id) {
    if (id is int) {
      return id;
    }
    if (id is String) {
      return int.tryParse(id);
    }
    return null;
  }
}

OpenTool _buildOpenTool() {
  final stringSchema = Schema(type: SchemaType.STRING);
  final intSchema = Schema(type: SchemaType.INTEGER);
  final functions = <FunctionModel>[
    FunctionModel(
      name: 'count',
      description: 'Count records.',
      parameters: const [],
    ),
    FunctionModel(
      name: 'create',
      description: 'Create a record.',
      parameters: [
        Parameter(
          name: 'text',
          description: 'Text to store.',
          schema: stringSchema,
          required: true,
        ),
      ],
    ),
    FunctionModel(
      name: 'read',
      description: 'Read a record by id.',
      parameters: [
        Parameter(
          name: 'id',
          description: 'Record id.',
          schema: intSchema,
          required: true,
        ),
      ],
    ),
    FunctionModel(
      name: 'list',
      description: 'List all records.',
      parameters: const [],
    ),
    FunctionModel(
      name: 'sequentiallyRead',
      description: 'Read records sequentially.',
      parameters: const [],
    ),
    FunctionModel(
      name: 'update',
      description: 'Update a record.',
      parameters: [
        Parameter(
          name: 'id',
          description: 'Record id.',
          schema: intSchema,
          required: true,
        ),
        Parameter(
          name: 'text',
          description: 'New text.',
          schema: stringSchema,
          required: true,
        ),
      ],
    ),
    FunctionModel(
      name: 'delete',
      description: 'Delete a record.',
      parameters: [
        Parameter(
          name: 'id',
          description: 'Record id.',
          schema: intSchema,
          required: true,
        ),
      ],
    ),
    FunctionModel(
      name: 'run',
      description: 'Trigger a mock error.',
      parameters: const [],
    ),
  ];

  return OpenTool(
    opentool: '1.1.0',
    info: Info(
      title: 'MockCRUD',
      description: 'Local mock CRUD tool.',
      version: '1.0.0',
    ),
    functions: functions,
  );
}
