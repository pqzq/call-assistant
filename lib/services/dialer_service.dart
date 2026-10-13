import 'package:url_launcher/url_launcher.dart';

/// 调起系统拨号页（tel:），号码会自动填入，但不会自动拨出（无需 CALL_PHONE 权限）。
class DialerService {
  const DialerService._();

  static Future<bool> dial(String? phone) async {
    final target = _buildTelUri(phone);
    if (target == null) return false;
    try {
      // 默认模式即可跳到系统拨号盘；Android 上 url_launcher 会用 ACTION_DIAL 交给系统应用
      return await launchUrl(target);
    } catch (_) {
      return false;
    }
  }

  static Uri? _buildTelUri(String? phone) {
    if (phone == null) return null;
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.isEmpty) return null;
    // tel: URI 中的 '+' 需要转义，否则会被当成空格
    final escaped = digits.startsWith('+') ? digits.replaceAll('+', '%2B') : digits;
    return Uri.parse('tel:$escaped');
  }
}