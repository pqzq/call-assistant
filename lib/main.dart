import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'services/platform_bridge.dart';
import 'services/prompt_link.dart';
import 'widgets/floating_avatar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 双机联动：提前初始化（恢复设置、启动局域网监听、订阅通话状态）
  PromptLink.instance.init();
  PlatformBridge.logPlatformInfo();
  runApp(const CallAssistantApp());
}

/// 桌面端内容最大宽度（窗口再宽也不会把手机布局拉散）
const double kDesktopContentMaxWidth = 760;

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
      // 数字人浮在所有页面之上，可拖动
      builder: (context, child) {
        final content = FloatingAvatarHost(child: child ?? const SizedBox.shrink());
        if (!PlatformBridge.isDesktop) return content;
        // 桌面端：内容限宽居中，避免手机布局被宽屏拉散
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kDesktopContentMaxWidth),
            child: content,
          ),
        );
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