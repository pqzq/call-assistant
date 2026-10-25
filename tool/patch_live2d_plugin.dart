// 给 flutter_live2d 插件打本地补丁（幂等，可重复执行）。
//
// 背景：`flutter_live2d` 1.0.2 原生后端在真机上有一系列上游缺陷（无 GL context
// 线程初始化导致空白、shader 没进 assets、按 canvas cover 适配裁切、贴边映射
// 不可靠、嘴型每帧被重置、触摸吞事件等）。我们在 fork 的 cpp 源码里逐一修好，
// 并把**最终正确的 C++ 文件整份存进仓库 `tool/patches/`**，本脚本把它们覆盖到
// pub cache。
//
// 为什么用「整文件覆盖」而不是逐处文本替换：
//   早先版本用一串 anchored 文本 edit 增量改 cpp，但那些 oldText 是照着被反复
//   改过的本地 cache 写的，跟 pub.dev 原始文件对不上；本地靠 marker 幂等跳过看
//   不出问题，CI 的干净 pub cache 逐条应用就会「找不到要替换的代码」而失败。
//   整文件覆盖不依赖任何锚点匹配，只要版本是 1.0.2 就能精确复现产物，最稳。
//
// view.dart / Live2DPlatformView.kt 两处改动很小且 oldText 与原始文件一致，
// 仍用文本 edit（保留可读性）。若将来升级 flutter_live2d 版本：需重新比对
// tool/patches/ 下的 cpp 是否仍适用，必要时更新覆盖文件。
//
// 用法：dart run tool/patch_live2d_plugin.dart
// `flutter pub get` 之后（pub cache 可能被重置）需重新执行一次。

import 'dart:convert';
import 'dart:io';

const String _pluginName = 'flutter_live2d';

/// cpp 源码目录（相对插件根）
const String _cppDir = 'android/src/main/cpp';

/// 整文件覆盖清单：仓库 tool/patches/ 下的同名文件 → 插件 `_cppDir` 目录下
const List<String> _overlayFiles = <String>[
  'live2d_flutter.cpp',
  'Live2DModel.hpp',
  'Live2DModel.cpp',
];

/// 小改动仍用文本替换（`old` → `new`）
class _Edit {
  const _Edit(this.file, this.oldText, this.newText, {this.marker});

  final String file;
  final String oldText;
  final String newText;

  /// 幂等标记：文件里已包含该字符串就跳过
  final String? marker;
}

const List<_Edit> _edits = <_Edit>[
  // 触摸穿透：平台视图独吞触摸会让外层 GestureDetector 收不到拖动/点击事件
  _Edit(
    'lib/src/view.dart',
    '''        hitTestBehavior: PlatformViewHitTestBehavior.opaque,''',
    '''        // 用 transparent 而不是 opaque：opaque 会让平台视图**独吞所有触摸**，
        // 外层 Flutter 的 GestureDetector（拖动数字人、点击缩小模型恢复展开）
        // 都收不到事件。
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,''',
    marker: 'PlatformViewHitTestBehavior.transparent',
  ),
  _Edit(
    'android/src/main/kotlin/com/linh18nd/flutter_live2d/Live2DPlatformView.kt',
    '''        return true
    }

    override fun onSurfaceTextureAvailable''',
    '''        // 返回 false：让事件继续冒泡给 Flutter（外层 GestureDetector 要靠它拖动数字人）
        return false
    }

    override fun onSurfaceTextureAvailable''',
    marker: '返回 false：让事件继续冒泡给 Flutter',
  ),
];

Future<void> main() async {
  final pluginDir = _locatePlugin();
  if (pluginDir == null) {
    stderr.writeln('找不到 $_pluginName，请先执行 `flutter pub get`');
    exitCode = 1;
    return;
  }
  stdout.writeln('插件目录: ${pluginDir.path}');

  var changed = 0;
  changed += _overlayCpp(pluginDir);
  changed += _applyEdits(pluginDir);
  changed += _copyShaders(pluginDir);

  stdout.writeln(changed == 0 ? '全部已就绪，无需改动。' : '完成，共 $changed 处改动。');
  if (changed > 0) {
    stdout.writeln('提示：需要重新执行 `flutter build`（C++ 会重新编译）。');
  }
}

/// 把 tool/patches/ 下的最终 cpp 整份覆盖到插件源码目录
int _overlayCpp(Directory pluginDir) {
  var changed = 0;
  for (final name in _overlayFiles) {
    final src = File('tool/patches/$name');
    if (!src.existsSync()) {
      stderr.writeln('✗ 覆盖源缺失: tool/patches/$name');
      exitCode = 1;
      continue;
    }
    final dst = File('${pluginDir.path}/$_cppDir/$name');
    final srcBytes = src.readAsBytesSync();
    if (dst.existsSync() && _sameBytes(dst.readAsBytesSync(), srcBytes)) {
      stdout.writeln('= 已是最新: $_cppDir/$name');
      continue;
    }
    dst.parent.createSync(recursive: true);
    dst.writeAsBytesSync(srcBytes);
    stdout.writeln('✓ 已覆盖: $_cppDir/$name');
    changed++;
  }
  return changed;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _applyEdits(Directory pluginDir) {
  var changed = 0;
  for (final edit in _edits) {
    final file = File('${pluginDir.path}/${edit.file}');
    if (!file.existsSync()) {
      stderr.writeln('✗ 文件不存在: ${edit.file}');
      exitCode = 1;
      continue;
    }
    final text = file.readAsStringSync();
    if (edit.marker != null && text.contains(edit.marker!)) {
      stdout.writeln('= 已打过补丁: ${edit.file}');
      continue;
    }
    if (!text.contains(edit.oldText)) {
      stderr.writeln('✗ 找不到要替换的代码（插件版本可能变了）: ${edit.file} / marker=${edit.marker}');
      exitCode = 1;
      continue;
    }
    file.writeAsStringSync(text.replaceFirst(edit.oldText, edit.newText));
    stdout.writeln('✓ 已修改: ${edit.file}');
    changed++;
  }
  return changed;
}

/// 从 package_config.json 定位插件目录
Directory? _locatePlugin() {
  final configFile = File('.dart_tool/package_config.json');
  if (configFile.existsSync()) {
    final json = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    final packages = json['packages'] as List<dynamic>? ?? <dynamic>[];
    for (final p in packages) {
      final map = p as Map<String, dynamic>;
      if (map['name'] != _pluginName) continue;
      final rootUri = map['rootUri'] as String? ?? '';
      final resolved = rootUri.startsWith('file://')
          ? Uri.parse(rootUri).toFilePath()
          : '${Directory.current.path}/$rootUri';
      final dir = Directory(resolved);
      if (dir.existsSync()) return dir;
    }
  }
  // 兜底：直接在 pub cache 里找
  final pubCache = Platform.environment['PUB_CACHE'] ??
      (Platform.isWindows
          ? '${Platform.environment['LOCALAPPDATA']}\\Pub\\Cache'
          : '${Platform.environment['HOME']}/.pub-cache');
  final hosted = Directory('$pubCache/hosted/pub.dev');
  if (!hosted.existsSync()) return null;
  final dirs = hosted
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.replaceAll('\\', '/').split('/').last.startsWith('$_pluginName-'))
      .toList();
  if (dirs.isEmpty) return null;
  dirs.sort((a, b) => a.path.compareTo(b.path));
  return dirs.last;
}

/// 把 StandardES 下的 shader 复制到 APK 的 assets/FrameworkShaders
int _copyShaders(Directory pluginDir) {
  final src = Directory(
    '${pluginDir.path}/android/src/main/cpp/CubismFramework/Rendering/OpenGL/Shaders/StandardES',
  );
  final dst = Directory('${pluginDir.path}/android/src/main/assets/FrameworkShaders');
  if (!src.existsSync()) {
    stderr.writeln('✗ 找不到 shader 源目录: ${src.path}');
    exitCode = 1;
    return 0;
  }
  dst.createSync(recursive: true);

  var copied = 0;
  for (final entity in src.listSync()) {
    if (entity is! File) continue;
    final name = entity.path.replaceAll('\\', '/').split('/').last;
    if (!name.endsWith('.vert') && !name.endsWith('.frag')) continue;
    final target = File('${dst.path}/$name');
    // 内容一致就跳过
    if (target.existsSync() &&
        _sameBytes(target.readAsBytesSync(), entity.readAsBytesSync())) {
      continue;
    }
    entity.copySync(target.path);
    copied++;
  }
  stdout.writeln(copied == 0
      ? '= shader 已就绪（${dst.path}）'
      : '✓ 已复制 $copied 个 shader 到 assets/FrameworkShaders');
  return copied;
}
