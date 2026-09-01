import 'package:cron/cron.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

/// Raised when a Cron task contains a timezone that is not in the IANA
/// database bundled with the kernel.
class CronTimezoneException extends FormatException {
  CronTimezoneException(String timezoneName)
    : super('Unknown IANA timezone: $timezoneName');
}

/// Timezone helpers used by both Cron scheduling and Agent prompt injection.
class CronTimeZone {
  static bool _initialized = false;

  static String? normalize(String? timezoneName) {
    final normalized = timezoneName?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  static void validate(String? timezoneName) {
    locationFor(timezoneName);
  }

  static timezone.Location? locationFor(String? timezoneName) {
    final normalized = normalize(timezoneName);
    if (normalized == null) {
      return null;
    }
    _ensureInitialized();
    try {
      return timezone.getLocation(normalized);
    } on Object {
      throw CronTimezoneException(normalized);
    }
  }

  /// Converts an instant to the task's wall-clock time.
  ///
  /// A missing timezone intentionally follows the server's local timezone,
  /// preserving the pre-existing Cron behavior.
  static DateTime toTaskLocal(DateTime instant, {String? timezoneName}) {
    final location = locationFor(timezoneName);
    if (location == null) {
      return instant.toLocal();
    }
    return timezone.TZDateTime.from(instant.toUtc(), location);
  }

  /// Converts a wall-clock candidate to its UTC instant.
  ///
  /// The timezone package normalizes a wall-clock value in a spring DST gap to
  /// a different wall-clock value. That mismatch is used to implement the
  /// policy that nonexistent local times are skipped. Ambiguous autumn values
  /// resolve to one instant, so a local slot is considered only once.
  static DateTime? localWallToUtc(DateTime wallTime, {String? timezoneName}) {
    final location = locationFor(timezoneName);
    if (location == null) {
      return DateTime(
        wallTime.year,
        wallTime.month,
        wallTime.day,
        wallTime.hour,
        wallTime.minute,
        wallTime.second,
        wallTime.millisecond,
        wallTime.microsecond,
      ).toUtc();
    }

    final resolved = timezone.TZDateTime(
      location,
      wallTime.year,
      wallTime.month,
      wallTime.day,
      wallTime.hour,
      wallTime.minute,
      wallTime.second,
      wallTime.millisecond,
      wallTime.microsecond,
    );
    if (!_hasSameWallTime(resolved, wallTime)) {
      return null;
    }
    return resolved.toUtc();
  }

  static bool _hasSameWallTime(DateTime first, DateTime second) {
    return first.year == second.year &&
        first.month == second.month &&
        first.day == second.day &&
        first.hour == second.hour &&
        first.minute == second.minute &&
        first.second == second.second &&
        first.millisecond == second.millisecond &&
        first.microsecond == second.microsecond;
  }

  static void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    timezone_data.initializeTimeZones();
    _initialized = true;
  }
}

/// Computes the next actual UTC instant for a cron expression.
class CronScheduleCalculator {
  static const int _maxSearchDays = 366 * 8;

  static DateTime? nextRunAt({
    required String schedule,
    String? timezoneName,
    DateTime? after,
  }) {
    final fields = _scheduleFields(schedule);
    final parsed = Schedule.parse(schedule);
    final normalizedTimezone = CronTimeZone.normalize(timezoneName);
    CronTimeZone.validate(normalizedTimezone);

    final afterUtc = (after ?? DateTime.now()).toUtc();
    final localAfter = CronTimeZone.toTaskLocal(
      afterUtc,
      timezoneName: normalizedTimezone,
    );
    final wallAfter = DateTime.utc(
      localAfter.year,
      localAfter.month,
      localAfter.day,
      localAfter.hour,
      localAfter.minute,
      localAfter.second,
      localAfter.millisecond,
      localAfter.microsecond,
    );
    var date = DateTime.utc(localAfter.year, localAfter.month, localAfter.day);
    final lastDate = date.add(const Duration(days: _maxSearchDays));

    final hours = _values(parsed.hours, min: 0, max: 23);
    final minutes = _values(parsed.minutes, min: 0, max: 59);
    final seconds = fields.length == 6
        ? _values(parsed.seconds, min: 0, max: 59)
        : const <int>[0];
    if (hours.isEmpty || minutes.isEmpty || seconds.isEmpty) {
      return null;
    }

    while (!date.isAfter(lastDate)) {
      if (_dateMatches(parsed, date)) {
        for (final hour in hours) {
          for (final minute in minutes) {
            for (final second in seconds) {
              final candidate = DateTime.utc(
                date.year,
                date.month,
                date.day,
                hour,
                minute,
                second,
              );
              if (!candidate.isAfter(wallAfter) ||
                  !parsed.shouldRunAt(candidate)) {
                continue;
              }
              final candidateUtc = CronTimeZone.localWallToUtc(
                candidate,
                timezoneName: normalizedTimezone,
              );
              if (candidateUtc != null && candidateUtc.isAfter(afterUtc)) {
                return candidateUtc;
              }
            }
          }
        }
      }
      date = date.add(const Duration(days: 1));
    }
    return null;
  }

  static List<String> _scheduleFields(String schedule) {
    final fields = schedule
        .trim()
        .split(RegExp(r'\s+'))
        .where((field) => field.isNotEmpty)
        .toList(growable: false);
    if (fields.length != 5 && fields.length != 6) {
      throw ScheduleParseException(
        'Cron schedule must contain five or six fields.',
      );
    }
    return fields;
  }

  static List<int> _values(
    List<int>? values, {
    required int min,
    required int max,
  }) {
    if (values == null) {
      return [for (var value = min; value <= max; value++) value];
    }
    return values.where((value) => value >= min && value <= max).toList();
  }

  static bool _dateMatches(Schedule schedule, DateTime date) {
    return (schedule.days == null || schedule.days!.contains(date.day)) &&
        (schedule.months == null || schedule.months!.contains(date.month)) &&
        (schedule.weekdays == null ||
            schedule.weekdays!.contains(date.weekday));
  }
}
