import 'package:shared_preferences/shared_preferences.dart';

/// 已呼叫号码的本地持久化（避免每次启动都丢失标记）。
class CallLogStore {
  const CallLogStore._();

  static const String _key = 'called_phones';

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

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, '');
    } catch (_) {
      // ignore
    }
  }
}