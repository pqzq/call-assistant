import 'package:shared_preferences/shared_preferences.dart';

/// 已呼叫号码的本地持久化（避免每次启动都丢失标记）。
/// 同时记录每个号码的最近拨打时间，供提词气泡显示「上次联系」。
class CallLogStore {
  const CallLogStore._();

  static const String _key = 'called_phones';
  static const String _timeKey = 'called_times';

  static Future<Set<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key) ?? '';
      return raw
          .split('\n')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> save(Set<String> phones) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, phones.join('\n'));
    } catch (_) {
      // 存储失败不影响主流程
    }
  }

  /// 号码 -> 最近拨打时间
  static Future<Map<String, DateTime>> loadTimes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_timeKey) ?? '';
      final result = <String, DateTime>{};
      for (final line in raw.split('\n')) {
        final parts = line.split('=');
        if (parts.length != 2) continue;
        final millis = int.tryParse(parts[1].trim());
        if (millis == null) continue;
        result[parts[0].trim()] = DateTime.fromMillisecondsSinceEpoch(millis);
      }
      return result;
    } catch (_) {
      return <String, DateTime>{};
    }
  }

  /// 记录一次拨打时间（在 [loadTimes] 结果上合并后写回）
  static Future<void> recordCall(String phone, {Map<String, DateTime>? times}) async {
    if (phone.isEmpty) return;
    try {
      final merged = times == null ? await loadTimes() : Map<String, DateTime>.of(times);
      merged[phone] = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _timeKey,
        merged.entries.map((e) => '${e.key}=${e.value.millisecondsSinceEpoch}').join('\n'),
      );
    } catch (_) {
      // ignore
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, '');
      await prefs.setString(_timeKey, '');
    } catch (_) {
      // ignore
    }
  }
}
