import 'package:json_annotation/json_annotation.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

part 'dto.g.dart';

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IntentRequestDto {
  final String source;
  final List<Content> content;
  final IntentHintsDto? hints;

  const IntentRequestDto({
    required this.source,
    required this.content,
    this.hints,
  });

  factory IntentRequestDto.fromJson(Map<String, dynamic> json) =>
      _$IntentRequestDtoFromJson(json);

  Map<String, dynamic> toJson() => _$IntentRequestDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IntentHintsDto {
  final List<String>? allowedActions;
  final List<String>? preferredApps;
  final Map<String, dynamic>? extra;

  const IntentHintsDto({
    this.allowedActions,
    this.preferredApps,
    this.extra,
  });

  factory IntentHintsDto.fromJson(Map<String, dynamic> json) =>
      _$IntentHintsDtoFromJson(json);

  Map<String, dynamic> toJson() => _$IntentHintsDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IntentResponseDto {
  final List<IntentCandidateDto> candidates;

  const IntentResponseDto({
    required this.candidates,
  });

  factory IntentResponseDto.fromJson(Map<String, dynamic> json) =>
      _$IntentResponseDtoFromJson(json);

  Map<String, dynamic> toJson() => _$IntentResponseDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IntentCandidateDto {
  final String action;
  final Map<String, dynamic> payload;
  final double? confidence;
  final String? reason;
  final FunctionCallDto? call;

  const IntentCandidateDto({
    required this.action,
    required this.payload,
    this.confidence,
    this.reason,
    this.call,
  });

  factory IntentCandidateDto.fromJson(Map<String, dynamic> json) =>
      _$IntentCandidateDtoFromJson(json);

  Map<String, dynamic> toJson() => _$IntentCandidateDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class FunctionCallDto {
  final String name;
  final Map<String, dynamic> arguments;

  const FunctionCallDto({
    required this.name,
    required this.arguments,
  });

  factory FunctionCallDto.fromJson(Map<String, dynamic> json) =>
      _$FunctionCallDtoFromJson(json);

  Map<String, dynamic> toJson() => _$FunctionCallDtoToJson(this);
}
