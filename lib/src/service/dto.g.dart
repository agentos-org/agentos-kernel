// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

IntentRequestDto _$IntentRequestDtoFromJson(Map<String, dynamic> json) =>
    IntentRequestDto(
      source: json['source'] as String,
      content: (json['content'] as List<dynamic>)
          .map((e) => Content.fromJson(e as Map<String, dynamic>))
          .toList(),
      hints: json['hints'] == null
          ? null
          : IntentHintsDto.fromJson(json['hints'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$IntentRequestDtoToJson(IntentRequestDto instance) {
  final val = <String, dynamic>{
    'source': instance.source,
    'content': instance.content.map((e) => e.toJson()).toList(),
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('hints', instance.hints?.toJson());
  return val;
}

IntentHintsDto _$IntentHintsDtoFromJson(Map<String, dynamic> json) =>
    IntentHintsDto(
      allowedActions: (json['allowedActions'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      preferredApps: (json['preferredApps'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      extra: json['extra'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$IntentHintsDtoToJson(IntentHintsDto instance) {
  final val = <String, dynamic>{};

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('allowedActions', instance.allowedActions);
  writeNotNull('preferredApps', instance.preferredApps);
  writeNotNull('extra', instance.extra);
  return val;
}

IntentResponseDto _$IntentResponseDtoFromJson(Map<String, dynamic> json) =>
    IntentResponseDto(
      candidates: (json['candidates'] as List<dynamic>)
          .map((e) => IntentCandidateDto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$IntentResponseDtoToJson(IntentResponseDto instance) {
  final val = <String, dynamic>{};
  val['candidates'] = instance.candidates.map((e) => e.toJson()).toList();
  return val;
}

IntentCandidateDto _$IntentCandidateDtoFromJson(Map<String, dynamic> json) =>
    IntentCandidateDto(
      action: json['action'] as String,
      payload: json['payload'] as Map<String, dynamic>,
      confidence: (json['confidence'] as num?)?.toDouble(),
      reason: json['reason'] as String?,
      call: json['call'] == null
          ? null
          : FunctionCallDto.fromJson(json['call'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$IntentCandidateDtoToJson(IntentCandidateDto instance) {
  final val = <String, dynamic>{
    'action': instance.action,
    'payload': instance.payload,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('confidence', instance.confidence);
  writeNotNull('reason', instance.reason);
  writeNotNull('call', instance.call?.toJson());
  return val;
}

FunctionCallDto _$FunctionCallDtoFromJson(Map<String, dynamic> json) =>
    FunctionCallDto(
      name: json['name'] as String,
      arguments: json['arguments'] as Map<String, dynamic>,
    );

Map<String, dynamic> _$FunctionCallDtoToJson(FunctionCallDto instance) =>
    <String, dynamic>{
      'name': instance.name,
      'arguments': instance.arguments,
    };
