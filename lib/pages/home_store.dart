import 'dart:convert';
import 'dart:developer';

import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:mobx/mobx.dart';
import 'package:screwdriver/screwdriver.dart';
import 'package:toggl_target/model/time_entry.dart';
import 'package:toggl_target/pages/target_store.dart';
import 'package:toggl_target/utils/system_tray_manager.dart';
import 'package:toggl_target/utils/utils.dart';

import '../resources/keys.dart';

part 'home_store.g.dart';

// ignore: library_private_types_in_public_api
class HomeStore = _HomeStore with _$HomeStore;

abstract class _HomeStore with Store {
  late final TargetStore targetStore = GetIt.instance.get<TargetStore>();
  late final SystemTrayManager systemTrayManager =
      GetIt.instance.get<SystemTrayManager>();

  late final Box secretsBox = getSecretsBox();
  late final Box settingsBox = getAppSettingsBox();

  _HomeStore() {
    init();
  }

  @observable
  DateTime? lastUpdated;

  @observable
  List<TimeEntry>? timeEntries;

  @observable
  bool isLoading = true;

  @observable
  String? error;

  @observable
  Duration completed = Duration.zero;

  @observable
  Map<DateTime, Duration> durationPerDay = {};

  @computed
  Duration get todayDuration => durationPerDay[today] ?? Duration.zero;

  @computed
  Duration get completedTillToday => completed - todayDuration;

  @computed
  bool get isLoadingWithData => isLoading && (timeEntries?.isNotEmpty == true);

  @computed
  Duration get remaining {
    final diff = targetStore.requiredTargetDuration - completed;
    if (diff.inSeconds % 60 > 0) {
      // round to 1 more minute if there are seconds less than a minute.
      return Duration(minutes: diff.inSeconds ~/ 60 + 1);
    }
    return diff;
  }

  @computed
  Duration get remainingTillToday {
    final diff = targetStore.requiredTargetDuration - completedTillToday;
    if (diff.inSeconds % 60 > 0) {
      // round to 1 more minute if there are seconds less than a minute.
      return Duration(minutes: diff.inSeconds ~/ 60 + 1);
    }
    return diff;
  }

  @observable
  Map<DateTime, List<TimeEntry>> groupedEntries = {};

  @computed
  Duration get dailyAverageTarget => Duration(
      minutes:
          (remaining.inMinutes / targetStore.daysRemainingAfterToday).round());

  @computed
  Duration get dailyAverageTargetTillToday {
    return Duration(
        minutes:
            (remainingTillToday.inMinutes / targetStore.daysRemaining).round());
  }

  @computed
  double get todayPercentage =>
      (todayDuration.inMinutes / dailyAverageTargetTillToday.inMinutes)
          .roundToPrecision(4);

  @computed
  Duration get remainingForToday {
    final diff = dailyAverageTargetTillToday - todayDuration;
    if (diff.isNegative) return Duration.zero;

    if (diff.inSeconds % 60 > 0) {
      // round to 1 more minute if there are seconds less than a minute.
      return Duration(minutes: diff.inMinutes + 1);
    }
    return diff;
  }

  @computed
  Duration get effectiveAverageTarget {
    return todayPercentage > 1 ? dailyAverageTarget : dailyAverageTarget;
  }

  late String apiKey;
  late String fullName;
  late String email;
  late String timezone;
  late String avatarUrl;

  Future<void> init() async {
    apiKey = secretsBox.get(HiveKeys.apiKey);
    fullName = secretsBox.get(HiveKeys.fullName);
    email = secretsBox.get(HiveKeys.email);
    timezone = secretsBox.get(HiveKeys.timezone);
    avatarUrl = secretsBox.get(HiveKeys.avatarUrl) ?? '';

    await systemTrayManager.init();
    await refreshData();
  }

  void updateSystemTrayText() {
    String text;
    final percentage = (todayPercentage * 100).floor();
    if (percentage >= 100) {
      text = 'Completed';
    } else {
      text = '$percentage%';
    }

    systemTrayManager.setTitle(text);
  }

  Future<List<TimeEntry>?> fetchData() async {
    log('Fetching data...');
    try {
      final DateFormat format = DateFormat('yyyy-MM-dd');
      final String startDate =
          format.format(DateTime(targetStore.year, targetStore.month, 1));
      final String endDate =
          format.format(DateTime(targetStore.year, targetStore.month + 1, 0));
      final uri = Uri.parse(
          'https://api.track.toggl.com/api/v9/me/time_entries?start_date=$startDate&end_date=$endDate');
      log('Fetching data from $startDate to $endDate...');
      log('URL: $uri');
      final apiKey = secretsBox.get(HiveKeys.apiKey);
      final authKey = base64Encode('$apiKey:api_token'.codeUnits);
      final response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Basic $authKey',
        },
      );

      if (response.statusCode != 200) {
        log('Error', error: response.body);
        return null;
      }

      final List<JsonMap> data = List<JsonMap>.from(jsonDecode(response.body));

      final List<TimeEntry> timeEntries = data.map(TimeEntry.fromJson).toList();

      return timeEntries;
    } catch (error, stackTrace) {
      log('Error', error: error, stackTrace: stackTrace);
      rethrow;
    }
  }

  @action
  Future<void> refreshData() async {
    isLoading = true;
    systemTrayManager.setRefreshOption(enabled: false, label: 'Syncing...');
    try {
      // await Future.delayed(3.seconds);
      final List<TimeEntry>? data = await fetchData();
      if (data == null) {
        error = 'Error fetching data';
        isLoading = false;
        return;
      }
      processTimeEntries(data);
      timeEntries = data;
      isLoading = false;
      lastUpdated = DateTime.now();
      updateSystemTrayText();
    } catch (error, stackTrace) {
      log('Error', error: error, stackTrace: stackTrace);
      this.error = error.toString();
      isLoading = false;
    } finally {
      systemTrayManager.setRefreshOption(enabled: true);
    }
  }

  void dispose() {}

  void processTimeEntries(List<TimeEntry> entries) {
    log('Processing time entries...');

    final int? projectId = secretsBox.get(HiveKeys.projectId);
    final int? workspaceId = secretsBox.get(HiveKeys.workspaceId);

    List<TimeEntry> filtered = entries.where((item) {
      if (item.projectId == projectId && item.workspaceId == workspaceId) {
        return true;
      }
      if (workspaceId != null && item.workspaceId != workspaceId) {
        log('Skipping entry [${item.id}]: ${item.description} because workspaceId does not match!');
        return false;
      }
      if (projectId != null && item.projectId != projectId) {
        log('Skipping entry [${item.id}]: ${item.description} because projectId does not match!');
        return false;
      }
      return true;
    }).toList();

    // group entries
    groupedEntries = filtered.groupBy((entry) =>
        DateTime(entry.start.year, entry.start.month, entry.start.day));

    durationPerDay = groupedEntries.map((key, values) {
      final List<TimeEntry> entries = values;
      final Duration duration = entries.fold<Duration>(Duration.zero,
          (previousValue, element) => previousValue + element.duration);
      return MapEntry(key, duration);
    });

    completed = durationPerDay.values.fold<Duration>(
        Duration.zero, (previousValue, duration) => previousValue + duration);

    log('-------------------------------------------------------------------');
    log('Total duration: ${completed.inHours}:${completed.inMinutes.remainder(60)}');
    log('Required target: ${targetStore.requiredTargetDuration.inHours}:${targetStore.requiredTargetDuration.inMinutes.remainder(60)}');
    log('remaining: ${remaining.inHours}:${remaining.inMinutes.remainder(60)}');
    log('remainingTillToday: $remainingTillToday');
    log('currentDay: ${targetStore.currentDay}');
    log('daysRemainingAfterToday: ${targetStore.daysRemainingAfterToday}');
    log('effectiveDays: ${targetStore.effectiveDays.length}');
    log('dailyAverageTarget: $dailyAverageTarget');
    log('dailyAverageTargetTillToday: $dailyAverageTargetTillToday');
    log('today: $todayDuration');
    log('todayPercentage: $todayPercentage');
    log('effectiveAverageTarget: $effectiveAverageTarget');
    log('remainingForToday: $remainingForToday');
    log('-------------------------------------------------------------------');
  }
}
