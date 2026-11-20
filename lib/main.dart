import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import 'pages/home_page.dart';
import 'services/app_navigator.dart';
import 'services/app_notifier.dart';
import 'services/app_paths.dart';
import 'services/platform_bridge.dart';
import 'services/prompt_link.dart';
import 'widgets/desktop_split.dart';
import 'widgets/floating_avatar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 统一数据目录（含旧位置迁移）：必须在任何用到路径的服务之前初始化
  await AppPaths.init();
  // 系统通知：桌面端需要先 setup（Windows 会建一个开始菜单快捷方式当 AUMID）
  await AppNotifier.setup();
  // 双机联动：提前初始化（恢复设置、启动局域网监听、订阅通话状态）
  PromptLink.instance.init();
  PlatformBridge.logPlatformInfo();
  runApp(const CallAssistantApp());
}

class CallAssistantApp extends StatelessWidget {
  const CallAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2F6BFF),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: '话务助手',
      debugShowCheckedModeBanner: false,
      // 桌面端分栏在 Navigator 之外，需要全局 key 才能弹窗/弹 toast
      navigatorKey: appNavigatorKey,
      // 桌面端：左数字人 / 右主界面 分栏（数字人是原生 WebView，不再浮在内容上）
      // 手机端：数字人浮在所有页面之上，可拖动
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        if (PlatformBridge.isDesktop) {
          return DesktopSplitView(child: content);
        }
        return FloatingAvatarHost(child: content);
      },
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        // 显式指定字体，别靠「Roboto + 中文系统回退」：
        // Flutter 默认 fontFamily 是 Roboto（不含中文），中文走系统回退时
        // **字重可能不存在**，Skia 会合成加粗/变细，笔画就发虚。
        // Windows 的「Microsoft YaHei UI」是针对小字号做过字形优化的 UI 字体，
        // 比普通的「Microsoft YaHei」在 11~13px 下更清晰。
        fontFamily: PlatformBridge.isWindows ? 'Microsoft YaHei UI' : null,
        fontFamilyFallback: const <String>[
          'Microsoft YaHei UI',
          'Microsoft YaHei',
          // macOS / Linux 的回退，避免在那些平台反而变糊
          'PingFang SC',
          'Noto Sans CJK SC',
          'Noto Sans SC',
        ],
        // 与左右两栏的底色一致（左栏是渐变中间色，右栏各页也用这个值）
        scaffoldBackgroundColor: const Color(0xFFF1F5FF),
        appBarTheme: const AppBarTheme(
          // 直接用页面底色（不透明的 0xFFF1F5FF，与 scaffoldBackgroundColor 同值）：
          // 视觉上和「透出底色」一样完全融入页面，又不透明 ——
          // 状态栏后面有确定的浅色打底，配合下面的深色图标才看得清
          backgroundColor: Color(0xFFF1F5FF),
          surfaceTintColor: Colors.transparent,
          // 图标 / 操作按钮用主题蓝
          foregroundColor: Color(0xFF2F6BFF),
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          // 状态栏图标用**深色**：背景是浅色，白色图标会看不清。
          // （AppBar 背景与页面同色时它没法自己判断，必须显式指定）
          systemOverlayStyle: SystemUiOverlayStyle.dark,
          // ⚠️ 刻意不设 titleTextStyle：
          // 它是**新建**的 TextStyle，不继承 ThemeData.fontFamily，中文会回退到
          // Roboto 的 fallback，字重看着和左栏不一致。
          // 不设则用 textTheme.titleLarge（带主题字体），各页再用
          // kPageTitleStyle 覆盖字号/字重/颜色。
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          hintStyle: const TextStyle(color: Colors.black54, fontSize: 14),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF2F6BFF),
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}
