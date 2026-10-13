import 'package:shared_preferences/shared_preferences.dart';

import '../utils/phone_utils.dart';

/// 本地设置：固话区号等。
class SettingsStore {
  const SettingsStore._();

  static const String _areaCodeKey = 'landline_area_code';

  static Future<String> loadAreaCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return PhoneUtils.normalizeAreaCode(prefs.getString(_areaCodeKey)) ?? PhoneUtils.defaultAreaCode;
    } catch (_) {
      return PhoneUtils.defaultAreaCode;
    }
  }

  static Future<void> saveAreaCode(String areaCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final normalized = PhoneUtils.normalizeAreaCode(areaCode);
      if (normalized != null) {
        await prefs.setString(_areaCodeKey, normalized);
      }
    } catch (_) {
      // 忽略存储失败
    }
  }
}