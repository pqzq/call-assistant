// 给 flutter_live2d 插件打本地补丁（幂等，可重复执行）。
//
// 背景：`flutter_live2d` 1.0.2 在真机上「模型加载成功（loadModel 返回 true、
// 纹理上传成功、Cubism Core 正常初始化）但画面永远空白」。排查后确认是两个
// 上游 bug：
//
// 1. CubismFramework 在 **没有 GL context 的线程**初始化
//    `nativeCreateView()` 是在 Android 主线程调用的，里面直接
//    `CubismFramework::Initialize()` —— 它内部会 CreateRenderer 并生成
//    OpenGL shader program。没有 current EGL context 时 shader 全部编译失败，
//    program 恒为 0，之后每帧 `glUniform*` 都报 GL_INVALID_OPERATION (0x502)。
//    修复：把初始化延迟到 `nativeOnSurfaceCreated()`（render hub 线程，已 eglMakeCurrent）。
//
// 2. **shader 源文件没被打进 APK**
//    Cubism 通过 `Live2DPal::LoadFileAsBytes("FrameworkShaders/xxx")` 从 APK
//    assets 读 shader，但插件的 build.gradle.kts 只配了 `java.srcDirs`，
//    shader 文件躺在 cpp 源码目录里，从未进入 assets。
//    修复：把 `Shaders/StandardES/*` 复制到 `android/src/main/assets/FrameworkShaders/`。
//
// 用法：dart run tool/patch_live2d_plugin.dart
// 需要重跑 `flutter pub get` 之后重新执行一次（pub cache 可能被重置）。

import 'dart:convert';
import 'dart:io';

const String _pluginName = 'flutter_live2d';

/// cpp 文件里的文本替换（`old` → `new`）
class _Edit {
  const _Edit(this.file, this.oldText, this.newText, {this.marker});

  final String file;
  final String oldText;
  final String newText;

  /// 幂等标记：文件里已包含该字符串就跳过
  final String? marker;
}

const List<_Edit> _edits = <_Edit>[
  // ---- 1. 结构体加 frameworkRetained 标志 ----
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    bool                  surfaceNeedsInit = false;
    CubismMatrix44        projection;''',
    '''    bool                  surfaceNeedsInit = false;
    // CubismFramework 必须在**有 GL context** 时才初始化（它会生成 shader program），
    // 所以延迟到 nativeOnSurfaceCreated（render hub 线程，已 eglMakeCurrent）
    bool                  frameworkRetained = false;
    CubismMatrix44        projection;''',
    marker: 'frameworkRetained',
  ),

  // ---- 2. nativeCreateView 不再初始化 Framework ----
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeCreateView(JNIEnv*, jclass)
{
    FrameworkRetain();
    Live2DView* view = new Live2DView();''',
    '''Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeCreateView(JNIEnv*, jclass)
{
    // 注意：这里**不能**初始化 CubismFramework！
    // nativeCreateView 在 Android 主线程调用，此时没有 current EGL context，
    // 而 CubismFramework::Initialize() 内部会生成 OpenGL shader program，
    // 没有 context 时全部失败，之后每帧 glUniform* 都报 GL_INVALID_OPERATION，
    // 表现为「模型加载成功但画面永远空白」。
    // 真正的初始化放在 nativeOnSurfaceCreated（render hub 线程，已 eglMakeCurrent）。
    Live2DView* view = new Live2DView();''',
    marker: '这里**不能**初始化 CubismFramework',
  ),

  // ---- 3. nativeOnSurfaceCreated 里初始化 Framework + 透明清屏 ----
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    view->surfaceNeedsInit = true;

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);''',
    '''    view->surfaceNeedsInit = true;

    // 这里在 render hub 线程执行，EGL context 已 current ——
    // 是唯一安全的初始化 CubismFramework（含 shader program）的时机。
    if (!view->frameworkRetained)
    {
        FrameworkRetain();
        view->frameworkRetained = true;
    }

    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);''',
    marker: 'view->frameworkRetained = true;',
  ),

  // ---- 4. nativeDestroyView 配对释放 ----
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    delete view->textureManager;
    delete view;

    FrameworkRelease();
}''',
    '''    delete view->textureManager;
    const bool retained = view->frameworkRetained;
    delete view;

    // 只有真的在 surface created 时 retain 过，才需要 release（配对）
    if (retained)
    {
        FrameworkRelease();
    }
}''',
    marker: '只有真的在 surface created 时 retain 过',
  ),

  // ---- 5. 模型适配改成「按高度填满」（修裁头/裁脚） ----
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    if (view->width > view->height)
        view->model->GetModelMatrix()->SetHeight(2.0f);
    else
        view->model->GetModelMatrix()->SetWidth(2.0f);

    return true;''',
    '''    // 按「高度填满」适配：竖容器若用 SetWidth，瘦高模型（如 Natori）
    // 的高度会远超视口，头和脚都被裁掉（只剩半身）。
    // SetHeight 保证完整显示，且高度方向最大化利用。
    {
        const float aspect = (float)view->height / (float)view->width;
        const float targetH = 2.0f * (aspect > 1.0f ? aspect : 1.0f) * 1.12f;
        view->model->GetModelMatrix()->SetHeight(targetH);
    }

    return true;''',
    marker: '按「高度填满」适配',
  ),

  // ---- 6. nativeOnSurfaceChanged 里同步同样的适配策略 ----
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''        if (view->width > view->height)
            view->model->GetModelMatrix()->SetHeight(2.0f);
        else
            view->model->GetModelMatrix()->SetWidth(2.0f);''',
    '''        // 与 ReloadModelInternal 保持一致的「按高度填满」策略
        const float aspect = (float)view->height / (float)view->width;
        const float targetH = 2.0f * (aspect > 1.0f ? aspect : 1.0f) * 1.12f;
        view->model->GetModelMatrix()->SetHeight(targetH);''',
    marker: '与 ReloadModelInternal 保持一致的',
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
      stderr.writeln('✗ 找不到要替换的代码（插件版本可能变了）: ${edit.file}');
      exitCode = 1;
      continue;
    }
    file.writeAsStringSync(text.replaceFirst(edit.oldText, edit.newText));
    stdout.writeln('✓ 已修改: ${edit.file}');
    changed++;
  }

  changed += _copyShaders(pluginDir);

  stdout.writeln(changed == 0 ? '全部已就绪，无需改动。' : '完成，共 $changed 处改动。');
  if (changed > 0) {
    stdout.writeln('提示：需要重新执行 `flutter build`（C++ 会重新编译）。');
  }
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
        target.readAsBytesSync().toString() == entity.readAsBytesSync().toString()) {
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
