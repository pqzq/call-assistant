import 'sheet_data.dart';

/// 当前正在跟进的客户（用于浮动提词气泡）
class ActiveLead {
  const ActiveLead({
    required this.name,
    this.phone,
    this.extras = const <CellField>[],
    this.lastCalled,
  });

  /// 主标题（一般是姓名/单位）
  final String name;

  /// 本次拨打的号码
  final String? phone;

  /// 其余字段（单位、部门、备注…），气泡里最多展示 2 条
  final List<CellField> extras;

  /// 上次拨打时间
  final DateTime? lastCalled;

  /// 一行副标题：单位 · 备注
  String get subtitle {
    final values = extras
        .map((field) => field.value.trim())
        .where((value) => value.isNotEmpty)
        .take(2)
        .toList();
    return values.join(' · ');
  }

  String get lastCalledLabel {
    final time = lastCalled;
    if (time == null) return '首次联系';
    final now = DateTime.now();
    final sameDay = time.year == now.year && time.month == now.month && time.day == now.day;
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    if (sameDay) return '今天 $hh:$mm 拨过';
    final days = now.difference(time).inDays;
    if (days <= 0) return '$hh:$mm 拨过';
    if (days == 1) return '昨天 $hh:$mm 拨过';
    if (days < 30) return '$days 天前拨过';
    return '${time.month}-${time.day} 拨过';
  }

  ActiveLead copyWith({DateTime? lastCalled}) => ActiveLead(
        name: name,
        phone: phone,
        extras: extras,
        lastCalled: lastCalled ?? this.lastCalled,
      );
}
