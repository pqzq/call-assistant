import 'package:flutter/material.dart';

import '../models/sheet_data.dart';
import '../utils/phone_utils.dart';

/// 名单中的单条记录：标题 + 一个或多个可点击拨号的号码 + 其他字段。
class RecordCard extends StatelessWidget {
  const RecordCard({
    super.key,
    required this.rowNumber,
    required this.title,
    required this.phones,
    required this.fields,
    required this.called,
    required this.onTap,
    required this.onPhoneTap,
    this.highlighted = false,
  });

  /// 在表格中的行号（从 1 开始）
  final int rowNumber;

  final String title;

  /// 该行选中的所有号码（主列在前）
  final List<PhoneEntry> phones;

  final List<CellField> fields;

  /// 是否有任一号码已呼叫过
  final bool called;

  /// 正在拨打该行号码时高亮
  final bool highlighted;

  /// 点击卡片整体（号码多于一个时会弹出选择器）
  final VoidCallback onTap;

  /// 点击某个号码，直接拨该号码
  final ValueChanged<PhoneEntry> onPhoneTap;

  static const int maxVisibleFields = 5;
  static const int maxVisiblePhones = 3;

  /// 高亮时的背景色
  static const Color highlightColor = Color(0xFFE8F0FF);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPhone = phones.isNotEmpty;

    final borderColor = highlighted
        ? theme.colorScheme.primary
        : (called ? const Color(0xFFBFE5CD) : Colors.black12);

    return AnimatedContainer(
      key: ValueKey<String>('row_card_$rowNumber'),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: highlighted ? highlightColor : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: borderColor,
          width: highlighted ? 1.8 : 1,
        ),
        boxShadow: highlighted
            ? const <BoxShadow>[
                BoxShadow(color: Color(0x262F6BFF), blurRadius: 14, offset: Offset(0, 4)),
              ]
            : const <BoxShadow>[],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: hasPhone ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _indexBadge(theme, hasPhone),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (highlighted) ...<Widget>[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Text(
                                '正在拨打',
                                style: TextStyle(fontSize: 10, color: Colors.white),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (phones.isEmpty)
                        const Text('无号码', style: TextStyle(fontSize: 15, color: Colors.black38))
                      else
                        ...phones.take(maxVisiblePhones).map(_buildPhoneRow),
                      if (phones.length > maxVisiblePhones)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '还有 ${phones.length - maxVisiblePhones} 个号码…',
                            style: const TextStyle(fontSize: 11, color: Colors.black38),
                          ),
                        ),
                      if (fields.isNotEmpty) const SizedBox(height: 8),
                      ...fields.take(maxVisibleFields).map(_buildFieldRow),
                      if (fields.length > maxVisibleFields)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '还有 ${fields.length - maxVisibleFields} 项…',
                            style: const TextStyle(fontSize: 11, color: Colors.black38),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _callButton(hasPhone),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _indexBadge(ThemeData theme, bool hasPhone) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: highlighted
            ? theme.colorScheme.primary
            : (hasPhone ? const Color(0xFFE8EEFF) : Colors.black12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$rowNumber',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: highlighted
              ? Colors.white
              : (hasPhone ? theme.colorScheme.primary : Colors.black45),
        ),
      ),
    );
  }

  Widget _buildPhoneRow(PhoneEntry phone) {
    final disabled = !phone.valid;
    final color = disabled ? Colors.black38 : const Color(0xFF2F6BFF);
    return InkWell(
      onTap: disabled ? null : () => onPhoneTap(phone),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: <Widget>[
            Icon(_iconOf(phone.kind), size: 15, color: color),
            const SizedBox(width: 6),
            Text(phone.label, style: const TextStyle(fontSize: 11, color: Colors.black45)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                phone.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: color,
                ),
              ),
            ),
            if (phone.note != null)
              Container(
                margin: const EdgeInsets.only(left: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF4E0),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  phone.note!,
                  style: const TextStyle(fontSize: 10, color: Color(0xFFB26A00)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static IconData _iconOf(PhoneKind kind) {
    switch (kind) {
      case PhoneKind.mobile:
        return Icons.phone_iphone;
      case PhoneKind.landlineWithAreaCode:
      case PhoneKind.landlineLocal:
        return Icons.phone_in_talk_outlined;
      case PhoneKind.international:
        return Icons.public;
      case PhoneKind.unknown:
        return Icons.block;
    }
  }

  Widget _callButton(bool hasPhone) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: hasPhone ? const Color(0xFFE7F7EE) : Colors.black12,
        borderRadius: BorderRadius.circular(21),
      ),
      child: Icon(
        Icons.call,
        size: 20,
        color: hasPhone ? const Color(0xFF17A05A) : Colors.black26,
      ),
    );
  }

  Widget _buildFieldRow(CellField field) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 74,
            child: Text(
              field.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.black45),
            ),
          ),
          Expanded(
            child: Text(
              field.value,
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}