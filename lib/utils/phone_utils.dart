/// 号码类型
enum PhoneKind {
  /// 手机号，直接拨打
  mobile,

  /// 短号/服务号（10086 / 10010 / 10000），直接拨打
  service,

  /// 固话且已自带区号（02188886666 / 0571-88889999）
  landlineWithAreaCode,

  /// 本地座机，缺少区号，需要按设置补全（88886666）
  landlineLocal,

  /// 国际号码（+86 ...）
  international,

  /// 无法识别
  unknown,
}

/// 常用固话区号
class AreaCode {
  const AreaCode(this.code, this.city);

  final String code;
  final String city;

  String get label => '$code $city';
}

/// 号码文本解析工具：把 Excel 单元格里的各种写法统一成可拨号的号码。
///
/// 需要兼容的写法：
///   13800138000 / 138 0013 8000 / 138-0013-8000 / (010)88886666
///   +86 13800138000 / 13800138000.0 / 1.3800138E+10 / "13800138000 转 123"
///   88886666（本地座机，拨号时按设置自动补区号）
class PhoneUtils {
  const PhoneUtils._();

  static final RegExp _sciPattern = RegExp(r'^\d+(?:\.\d+)?[eE][+-]?\d+$');
  static final RegExp _trailingZeroPattern = RegExp(r'\.0+$');
  static final RegExp _separatorPattern = RegExp(r'[\s()（）\[\]【】\-—–－]');
  static final RegExp _extensionPattern = RegExp(r'(转接|转|分机|ext\.?|EXT\.?)');
  static final RegExp _nonDigitPattern = RegExp(r'\D');

  /// 中国大陆手机号
  static final RegExp _cnMobile = RegExp(r'^1[3-9]\d{9}$');

  /// 中国大陆固定电话且已带区号（01088886666 / 057188888888）
  static final RegExp _cnLandlineWithAreaCode = RegExp(r'^0\d{9,11}$');

  /// 本地座机，7~8 位且不以 0 开头（88886666 / 51234567）
  static final RegExp _localLandline = RegExp(r'^[2-9]\d{6,7}$');

  /// 短号/服务号，5~6 位且不以 0 开头（10086 移动 / 10010 联通 / 10000 电信 / 12345）
  /// 下限取 5 位是为了避开年份、编号这类 4 位数字（2024、1001）
  static final RegExp _serviceNumber = RegExp(r'^[1-9]\d{4,5}$');

  /// 其他国家/地区号码（8~15 位）
  static final RegExp _generic = RegExp(r'^\d{8,15}$');

  /// 区号：3 位或 4 位且以 0 开头
  static final RegExp _areaCodePattern = RegExp(r'^0\d{2,3}$');

  /// 默认固话区号
  static const String defaultAreaCode = '021';

  /// 常用区号，供界面快捷选择
  static const List<AreaCode> commonAreaCodes = <AreaCode>[
    AreaCode('021', '上海'),
    AreaCode('010', '北京'),
    AreaCode('020', '广州'),
    AreaCode('0755', '深圳'),
    AreaCode('0571', '杭州'),
    AreaCode('025', '南京'),
    AreaCode('027', '武汉'),
    AreaCode('022', '天津'),
    AreaCode('023', '重庆'),
    AreaCode('028', '成都'),
    AreaCode('0451', '哈尔滨'),
    AreaCode('0531', '济南'),
  ];

  /// 表头里出现这些关键词时，认为该列很可能是电话列
  static const List<String> headerKeywords = <String>[
    '手机',
    '电话',
    '联系',
    '联络',
    '号码',
    '移动电话',
    '座机',
    'phone',
    'mobile',
    'tel',
  ];

  /// 归一化：只保留数字（国际号码保留前导 +），无法解析时返回 null。
  static String? normalize(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.isEmpty) return null;

    // "13800138000 转 123" -> 取分机之前的主体号码
    final cut = text.split(_extensionPattern).first.trim();
    if (cut.isEmpty) return null;
    text = cut;

    // 科学计数法（长数字被 Excel 存成 1.3800138E+10）
    if (_sciPattern.hasMatch(text)) {
      final value = double.tryParse(text);
      if (value != null) text = value.toStringAsFixed(0);
    } else {
      // 13800138000.0 -> 13800138000
      text = text.replaceFirst(_trailingZeroPattern, '');
    }

    final hasPlus = text.startsWith('+');
    final digits = text.replaceAll(_separatorPattern, '').replaceAll(_nonDigitPattern, '');
    if (digits.isEmpty || digits.length > 15) return null;
    if (!hasPlus && digits.length < 3) return null;
    return hasPlus ? '+$digits' : digits;
  }

  /// 判断号码类型。
  static PhoneKind kindOf(String? raw) {
    final normalized = normalize(raw);
    if (normalized == null) return PhoneKind.unknown;
    if (normalized.startsWith('+')) return PhoneKind.international;
    if (_cnMobile.hasMatch(normalized)) return PhoneKind.mobile;
    if (_serviceNumber.hasMatch(normalized)) return PhoneKind.service;
    if (_cnLandlineWithAreaCode.hasMatch(normalized)) return PhoneKind.landlineWithAreaCode;
    if (_localLandline.hasMatch(normalized)) return PhoneKind.landlineLocal;
    return PhoneKind.unknown;
  }

  /// 是否是「缺区号的本地座机」，需要补区号后拨打。
  static bool needsAreaCode(String? raw) => kindOf(raw) == PhoneKind.landlineLocal;

  /// 校验并归一化区号：支持 21 / 021 / +86 021 等写法，非法返回 null。
  static String? normalizeAreaCode(String? code) {
    if (code == null) return null;
    var text = code.trim();
    if (text.isEmpty) return null;
    text = text.replaceAll(RegExp(r'[\s\-()]'), '');
    if (text.startsWith('+86')) {
      text = text.substring(3);
    } else if (text.startsWith('86') && text.length > 4) {
      text = text.substring(2);
    }
    if (!_areaCodePattern.hasMatch(text)) return null;
    return text;
  }

  /// 判断一段文本是否像电话号码（用于自动识别手机号列）。
  static bool looksLikePhone(String? raw) {
    final normalized = normalize(raw);
    if (normalized == null) return false;
    final digits = normalized.startsWith('+') ? normalized.substring(1) : normalized;
    if (_cnMobile.hasMatch(digits)) return true;
    if (_serviceNumber.hasMatch(digits)) return true;
    if (_cnLandlineWithAreaCode.hasMatch(digits)) return true;
    if (_localLandline.hasMatch(digits)) return true;
    return _generic.hasMatch(digits);
  }

  /// 可用于 tel: 的最终号码；本地座机会自动补上 areaCode。
  static String? dialTarget(String? raw, {String areaCode = defaultAreaCode}) {
    final normalized = normalize(raw);
    if (normalized == null) return null;
    final digits = normalized.replaceAll(_nonDigitPattern, '');
    if (digits.length < 3 || digits.length > 15) return null;

    if (needsAreaCode(normalized)) {
      final prefix = normalizeAreaCode(areaCode);
      if (prefix == null) return null;
      return '$prefix$digits';
    }
    return normalized;
  }

  /// 展示用格式：固话补横杠，如 02188886666 -> 021-88886666。
  static String prettyDial(String? digits) {
    if (digits == null || digits.isEmpty) return '';
    if (digits.startsWith('+')) return digits;
    if (digits.startsWith('0') && digits.length >= 10) {
      // 区号 3 位（北京/上海/广州…）或 4 位（0755/0571…）
      final areaLength = (digits[1] == '1' || digits[1] == '2') ? 3 : 4;
      if (digits.length > areaLength) {
        return '${digits.substring(0, areaLength)}-${digits.substring(areaLength)}';
      }
    }
    return digits;
  }

  /// 号码类型的中文名，用于界面提示。
  static String kindLabel(PhoneKind kind) {
    switch (kind) {
      case PhoneKind.mobile:
        return '手机';
      case PhoneKind.service:
        return '服务号';
      case PhoneKind.landlineWithAreaCode:
        return '固话';
      case PhoneKind.landlineLocal:
        return '本地座机';
      case PhoneKind.international:
        return '国际';
      case PhoneKind.unknown:
        return '未识别';
    }
  }

  /// 表头是否命中电话关键词。
  static bool hasPhoneKeyword(String? header) {
    if (header == null) return false;
    final text = header.trim().toLowerCase();
    if (text.isEmpty) return false;
    for (final keyword in headerKeywords) {
      if (text.contains(keyword)) return true;
    }
    return false;
  }
}