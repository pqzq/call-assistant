import 'dart:ui';

/// 浮动数字人的坐标换算（归一化 0~1 ↔ 像素），抽成纯函数便于测试。
class AvatarLayout {
  const AvatarLayout._();

  static double clamp01(double value) {
    if (value.isNaN) return 0;
    return value.clamp(0.0, 1.0);
  }

  /// 归一化坐标 → 像素坐标
  static Offset resolve(double x, double y, Size free) =>
      Offset(clamp01(x) * free.width, clamp01(y) * free.height);

  /// 像素坐标 → 归一化坐标；可用区域为 0 时返回 (0,0)
  static Offset normalize(Offset pixel, Size free) => Offset(
        free.width <= 0 ? 0 : clamp01(pixel.dx / free.width),
        free.height <= 0 ? 0 : clamp01(pixel.dy / free.height),
      );

  /// 把拖动后的像素坐标夹在可用区域内
  static Offset clampPixel(Offset pixel, Size free) {
    final normalized = normalize(pixel, free);
    return resolve(normalized.dx, normalized.dy, free);
  }
}
