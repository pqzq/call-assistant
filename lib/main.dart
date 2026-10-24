import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'services/app_navigator.dart';
import 'services/platform_bridge.dart';
import 'services/prompt_link.dart';
import 'widgets/desktop_split.dart';
import 'widgets/floating_avatar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
        scaffoldBackgroundColor: const Color(0xFFF4F6FB),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2F6BFF),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          hintStyle: const TextStyle(color: Colors.black38, fontSize: 14),
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
