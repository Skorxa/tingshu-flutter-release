import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ListeningStatsService extends ChangeNotifier {
  ListeningStatsService._();
  static final instance = ListeningStatsService._();

  static const _kTotalSeconds = 'listening_stats_total_seconds';
  static const _kTodaySeconds = 'listening_stats_today_seconds';
  static const _kTodayKey = 'listening_stats_today_key';

  int _totalSeconds = 0;
  int _todaySeconds = 0;
  String _todayKey = _dateKey(DateTime.now());
  int _pendingSeconds = 0;
  bool _ready = false;

  int get totalSeconds => _totalSeconds;
  int get todaySeconds => _todaySeconds;
  bool get ready => _ready;

  String get totalLabel => formatSeconds(_totalSeconds);
  String get todayLabel => formatSeconds(_todaySeconds);

  Future<void> init() async {
    if (_ready) return;
    final prefs = await SharedPreferences.getInstance();
    _totalSeconds = prefs.getInt(_kTotalSeconds) ?? 0;
    _todaySeconds = prefs.getInt(_kTodaySeconds) ?? 0;
    _todayKey = prefs.getString(_kTodayKey) ?? _dateKey(DateTime.now());
    await _rollTodayIfNeeded();
    _ready = true;
  }

  Future<void> addPlayedSeconds(int seconds) async {
    if (seconds <= 0) return;
    await _rollTodayIfNeeded();
    _totalSeconds += seconds;
    _todaySeconds += seconds;
    _pendingSeconds += seconds;
    if (_pendingSeconds >= 10) {
      _pendingSeconds = 0;
      await _persist();
    }
    notifyListeners();
  }

  Future<void> flush() async {
    if (_pendingSeconds <= 0) return;
    _pendingSeconds = 0;
    await _persist();
  }

  Future<void> _rollTodayIfNeeded() async {
    final current = _dateKey(DateTime.now());
    if (_todayKey == current) return;
    _todayKey = current;
    _todaySeconds = 0;
    _pendingSeconds = 0;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kTotalSeconds, _totalSeconds);
    await prefs.setInt(_kTodaySeconds, _todaySeconds);
    await prefs.setString(_kTodayKey, _todayKey);
  }

  static String formatSeconds(int seconds) {
    if (seconds <= 0) return '0 分钟';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours <= 0) return '${minutes.clamp(1, 59)} 分钟';
    if (minutes <= 0) return '$hours 小时';
    return '$hours 小时 $minutes 分钟';
  }

  static String _dateKey(DateTime value) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)}';
  }
}
