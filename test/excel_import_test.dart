import 'dart:convert';
import 'dart:typed_data';

import 'package:call_assistant/services/excel_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExcelService 导入容错', () {
    test('csv 文本可以直接解析', () {
      final csv = '姓名,手机号码,部门\n张伟,13800138000,销售一部\n李静,13900139001,销售二部\n';
      final sheets = ExcelService.parse(Uint8List.fromList(utf8.encode(csv)), fileName: '名单.csv');
      expect(sheets.length, 1);
      expect(sheets.first.name, '名单');
      expect(sheets.first.rowCount, 2);
      expect(sheets.first.phoneColumns, isNotEmpty);
      expect(sheets.first.cellAt(0, 0), '张伟');
    });

    test('带引号与逗号的字段能正确拆分', () {
      final csv = '姓名,备注\n王强,"重点客户, 需要跟进"\n';
      final sheets = ExcelService.parse(Uint8List.fromList(utf8.encode(csv)), fileName: 'a.csv');
      expect(sheets.first.cellAt(0, 1), '重点客户, 需要跟进');
    });

    test('制表符分隔也能识别', () {
      final tsv = '姓名\t手机号码\n赵敏\t13600136003\n';
      final sheets = ExcelService.parse(Uint8List.fromList(utf8.encode(tsv)), fileName: 'a.tsv');
      expect(sheets.first.rowCount, 1);
      expect(sheets.first.cellAt(0, 1), '13600136003');
    });

    test('二进制文件报错时给出可读原因', () {
      final junk = Uint8List.fromList(List<int>.filled(64, 7));
      expect(
        () => ExcelService.parse(junk, fileName: 'a.xlsx'),
        throwsA(isA<ExcelParseException>()),
      );
    });

    test('空文件直接报错', () {
      expect(
        () => ExcelService.parse(Uint8List(0)),
        throwsA(isA<ExcelParseException>()),
      );
    });
  });
}
