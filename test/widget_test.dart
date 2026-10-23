import 'package:call_assistant/main.dart';
import 'package:call_assistant/widgets/record_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 读取某一行卡片容器的背景色，用于验证高亮状态
Color? _rowCardColor(WidgetTester tester, int rowNumber) {
  final container =
      tester.widget<AnimatedContainer>(find.byKey(ValueKey<String>('row_card_$rowNumber')));
  return (container.decoration! as BoxDecoration).color;
}

Future<void> _loadDemo(WidgetTester tester) async {
  await tester.pumpWidget(const CallAssistantApp());
  await tester.pumpAndSettle();
  await tester.tap(find.text('使用示例名单体验'));
  await tester.pumpAndSettle();
}

/// 名单列表容器：紧凑模式是 GridView，详细模式是 ListView
Finder _listFinder() => find.byWidgetPredicate((w) => w is ListView || w is GridView);

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(target, 120, scrollable: find.byType(Scrollable).first);
  }
  // scrollUntilVisible 只是滚到边缘，这里再确保完全进入可视区，否则 tap 会落空
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _openList(WidgetTester tester) async {
  // 「开始拨号」现在与「导入其他表格」并排放在列表底部，需要先滚动到
  await _scrollTo(tester, find.text('开始拨号'));
  await tester.tap(find.text('开始拨号'));
  await tester.pumpAndSettle();
}

Future<void> _switchToLandlineSheet(WidgetTester tester) async {
  await tester.drag(find.byType(ListView).first, const Offset(0, 900));
  await tester.pumpAndSettle();
  await tester.tap(find.text('客户名单（11 行）'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('固话名单（6 行）').last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('自动勾选多个号码列，可手动增减', (tester) async {
    await _loadDemo(tester);

    // 客户名单同时勾选了「手机号码」和「办公电话」
    await _scrollTo(tester, find.text('已选 2 列'));
    expect(find.text('已选 2 列'), findsOneWidget);

    await _scrollTo(tester, find.text('办公电话'));
    await tester.tap(find.text('办公电话'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('已选 1 列'));
    expect(find.text('已选 1 列'), findsOneWidget);

    await tester.tap(find.text('办公电话'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('已选 2 列'));
    expect(find.text('已选 2 列'), findsOneWidget);
  });

  testWidgets('一条记录有多个号码：点卡片弹出选择器', (tester) async {
    await _loadDemo(tester);
    await _openList(tester);

    expect(find.text('共 11 条，当前显示 11 条'), findsOneWidget);
    expect(find.text('号码列：手机号码 / 办公电话'), findsOneWidget);
    // 卡片上同时展示两个号码，并带列名
    expect(find.text('手机号码'), findsWidgets);
    expect(find.text('13800138000'), findsOneWidget);
    expect(find.text('010-88886666'), findsOneWidget);
    expect(find.text('张伟'), findsOneWidget);

    // 点击整张卡片 -> 打开选择器
    await tester.tap(find.text('张伟'));
    await tester.pumpAndSettle();
    expect(find.text('选择要拨打的号码'), findsOneWidget);
    expect(find.text('手机 · 手机号码'), findsOneWidget);
    expect(find.text('固话 · 办公电话'), findsOneWidget);

    // 选择其中一个号码后关闭面板
    await tester.tap(find.text('固话 · 办公电话'));
    await tester.pumpAndSettle();
    expect(find.text('选择要拨打的号码'), findsNothing);
  });

  testWidgets('点单个号码直接拨该号码', (tester) async {
    await _loadDemo(tester);
    await _openList(tester);

    await tester.tap(find.text('13800138000'));
    await tester.pumpAndSettle();
    expect(find.text('选择要拨打的号码'), findsNothing);
  });

  testWidgets('固话名单：本地座机自动补区号 021', (tester) async {
    await _loadDemo(tester);
    await _switchToLandlineSheet(tester);
    await _openList(tester);

    expect(find.text('共 6 条，当前显示 6 条'), findsOneWidget);
    expect(find.text('号码列：办公座机'), findsOneWidget);
    expect(find.text('021-88886666'), findsOneWidget);
    expect(find.text('已补区号 021'), findsAtLeastNWidgets(2));

    // 滚到底：已自带区号的号码保持原样
    await tester.drag(_listFinder().last, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('021-66668889'), findsOneWidget);
    expect(find.text('0571-88889900'), findsOneWidget);
  });

  testWidgets('可切换固话区号并即时生效', (tester) async {
    await _loadDemo(tester);

    await _scrollTo(tester, find.text('0755 深圳'));
    await tester.tap(find.text('0755 深圳'));
    await tester.pumpAndSettle();
    expect(find.text('当前 0755'), findsOneWidget);
    expect(find.text('示例：88886666 → 0755-88886666'), findsOneWidget);

    await _switchToLandlineSheet(tester);
    await _openList(tester);
    expect(find.text('0755-88886666'), findsOneWidget);
    expect(find.text('已补区号 0755'), findsAtLeastNWidgets(1));
  });

  testWidgets('拨号时高亮当前行，且不会自动消失', (tester) async {
    await _loadDemo(tester);
    await _openList(tester);

    expect(_rowCardColor(tester, 4), isNot(RecordCard.highlightColor));

    // 点第 1 行的号码 -> 触发拨打并高亮该行
    await tester.tap(find.text('13800138000'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_rowCardColor(tester, 4), RecordCard.highlightColor);
    expect(find.text('正在拨打'), findsOneWidget);
    // 其它行不高亮
    expect(_rowCardColor(tester, 5), isNot(RecordCard.highlightColor));

    // 长时间等待后高亮依然保留
    await tester.pump(const Duration(minutes: 5));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_rowCardColor(tester, 4), RecordCard.highlightColor);
    expect(find.text('正在拨打'), findsOneWidget);
  });

  testWidgets('刷新列表后清除高亮，重新拨打转移高亮', (tester) async {
    await _loadDemo(tester);
    await _openList(tester);

    await tester.tap(find.text('13800138000'));
    await tester.pumpAndSettle();
    expect(_rowCardColor(tester, 4), RecordCard.highlightColor);

    // 拨打第 2 行 -> 高亮转移
    await tester.tap(find.text('13900139001'));
    await tester.pumpAndSettle();
    expect(_rowCardColor(tester, 4), isNot(RecordCard.highlightColor));
    expect(_rowCardColor(tester, 5), RecordCard.highlightColor);

    // 刷新 -> 清除高亮
    await tester.tap(find.byTooltip('刷新列表'));
    await tester.pump();
    // 提示是居中浮层、会自动消失，断言要趁它还在
    expect(find.text('列表已刷新'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_rowCardColor(tester, 4), isNot(RecordCard.highlightColor));
    expect(_rowCardColor(tester, 5), isNot(RecordCard.highlightColor));
    expect(find.text('正在拨打'), findsNothing);
  });

  testWidgets('返回首页再进入列表时高亮已重置', (tester) async {
    await _loadDemo(tester);
    await _openList(tester);

    await tester.tap(find.text('13800138000'));
    await tester.pumpAndSettle();
    expect(_rowCardColor(tester, 4), RecordCard.highlightColor);

    // 返回首页
    await tester.pageBack();
    await tester.pumpAndSettle();
    // 重新进入列表（相当于重新导入后的刷新）
    await _openList(tester);
    expect(_rowCardColor(tester, 4), isNot(RecordCard.highlightColor));
  });

  testWidgets('通过选择器拨号同样高亮对应行', (tester) async {
    await _loadDemo(tester);
    await _openList(tester);

    await tester.tap(find.text('张伟'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('固话 · 办公电话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(_rowCardColor(tester, 4), RecordCard.highlightColor);
  });

  testWidgets('搜索无结果时给出空提示', (tester) async {
    await _loadDemo(tester);
    await _openList(tester);

    await tester.enterText(find.byType(TextField).first, '不存在的关键字');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的记录'), findsOneWidget);
  });
}