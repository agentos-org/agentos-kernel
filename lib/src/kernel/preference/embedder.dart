import 'dart:math';

abstract class PreferenceEmbedder {
  List<double> embed(String text);
}

class HashEmbedder implements PreferenceEmbedder {
  final int dimensions;

  HashEmbedder({this.dimensions = 8});

  @override
  List<double> embed(String text) {
    final values = List<double>.filled(dimensions, 0.0);
    var hash = 0;
    for (final codeUnit in text.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7fffffff;
      final index = hash % dimensions;
      values[index] += 1.0;
    }
    final norm = sqrt(values.fold<double>(0, (sum, v) => sum + v * v));
    if (norm == 0) {
      return values;
    }
    return values.map((v) => v / norm).toList(growable: false);
  }
}
