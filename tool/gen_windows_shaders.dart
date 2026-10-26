// 把桌面版(Standard) Cubism shader 生成为内嵌 C++ 字符串表
// （flutter_live2d_windows 插件用：win_shaders_data.h）。
// 升级 Cubism Framework 后重跑一次：dart run tool/gen_windows_shaders.dart
import 'dart:io';

void main() {
  final dir = Directory(
    r'plugins\flutter_live2d_windows\windows\third_party\CubismFramework\Rendering\OpenGL\Shaders\Standard',
  );
  final out = File(
    r'plugins\flutter_live2d_windows\windows\live2d\win_shaders_data.h',
  );
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.vert') || f.path.endsWith('.frag'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln('no shader files found');
    exit(1);
  }

  final sb = StringBuffer()
    ..writeln('// 自动生成，勿手改：tool/gen_windows_shaders.dart')
    ..writeln('#pragma once')
    ..writeln('')
    ..writeln('#include <cstddef>')
    ..writeln('#include <cstring>')
    ..writeln('')
    ..writeln('// { 文件名, GLSL 源码 } 交替排列，末尾 nullptr 结束')
    ..writeln('static const char* kEmbeddedShaders[] = {');
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    var src = f.readAsStringSync();
    if (src.contains(')cubism(')) {
      stderr.writeln('shader $name contains raw-string terminator, abort');
      exit(1);
    }
    src = src.replaceAll('\r\n', '\n');
    sb.writeln('  "$name",');
    sb.writeln('  R"cubism($src)cubism",');
  }
  sb
    ..writeln('  nullptr')
    ..writeln('};')
    ..writeln('')
    ..writeln('// 按文件名查内嵌 shader；查不到返回 nullptr')
    ..writeln('inline const char* FindEmbeddedShader(const char* name) {')
    ..writeln('  if (!name) return nullptr;')
    ..writeln('  for (int i = 0; kEmbeddedShaders[i] != nullptr; i += 2) {')
    ..writeln('    if (std::strcmp(kEmbeddedShaders[i], name) == 0) return kEmbeddedShaders[i + 1];')
    ..writeln('  }')
    ..writeln('  return nullptr;')
    ..writeln('}');
  out.writeAsStringSync(sb.toString());
  stdout.writeln('generated ${files.length} shaders -> ${out.path}');
}
