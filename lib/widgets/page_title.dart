import 'package:material_ui/material_ui.dart';

/// 页面标题样式（左右两栏的标题栏统一用它）
///
/// ⚠️ **刻意不设 `fontFamily` / `fontFamilyFallback`**：
/// `TextStyle` 默认 `inherit: true`，会和上层 `DefaultTextStyle` 合并 ——
/// AppBar 用的是 `ThemeData.textTheme.titleLarge`（带主题字体），左栏用的是
/// Scaffold 的默认 body 样式。只要这里不写死字体，两边都继承到
/// `Microsoft YaHei UI`（Windows）/ 系统中文，字形和字重才真正一致。
///
/// 之前 AppBar 用 `titleTextStyle: TextStyle(...)`，它是**新建**的样式、
/// 不继承主题字体，中文回退到 Roboto 的 fallback，看着就和左栏不一样。
const TextStyle kPageTitleStyle = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w700,
  color: Color(0xFF1B2A44),
);
