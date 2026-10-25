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

  // ---- 4.5 nativeLoadModel 里确保 Framework 已初始化 ----
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    bool ok = false;
    if (view->width > 0 && view->height > 0)
    {
        ok = ReloadModelInternal(view, dir, file);
    }''',
    '''    bool ok = false;
    if (view->width > 0 && view->height > 0)
    {
        // 关掉数字人时 FrameworkRelease 会把 CubismFramework Dispose 掉。
        // 重新打开时如果 nativeOnSurfaceCreated 还没被调用（EGL surface 尚未就绪），
        // Framework 就是未初始化状态，CreateRenderer 会失败。
        // 这里补一次初始化 —— 当前已在 render hub 线程且 eglMakeCurrent 过了。
        if (!view->frameworkRetained)
        {
            FrameworkRetain();
            view->frameworkRetained = true;
        }
        ok = ReloadModelInternal(view, dir, file);
    }''',
    marker: '重新打开时如果 nativeOnSurfaceCreated 还没被调用',
  ),

  // ---- 4.6 嘴型参数：改成「每帧重新应用的外部参数」 ----
  // Update() 开头 _model->LoadParameters() 会重置所有参数，
  // 直接 SetParameterValue 的值活不过一帧 → 嘴型永远不动
  _Edit(
    'android/src/main/cpp/Live2DModel.hpp',
    '''#include <Type/csmVector.hpp>
#include <Math/CubismMatrix44.hpp>''',
    '''#include <Type/csmVector.hpp>
#include <Type/csmMap.hpp>
#include <Math/CubismMatrix44.hpp>''',
    marker: 'Type/csmMap.hpp',
  ),
  _Edit(
    'android/src/main/cpp/Live2DModel.hpp',
    '''    void SetParameterValue(const Csm::csmChar* parameterId, Csm::csmFloat32 value);''',
    '''    void SetParameterValue(const Csm::csmChar* parameterId, Csm::csmFloat32 value);

    /// 外部**持续驱动**的参数（嘴型等）。
    /// Update() 开头会 LoadParameters() 重置参数，直接 Set 的值活不过一帧，
    /// 这里缓存下来，在每帧 _model->Update() 之前重新应用。
    void SetExternalParameter(const Csm::csmChar* parameterId, Csm::csmFloat32 value);''',
    marker: '外部**持续驱动**的参数',
  ),
  _Edit(
    'android/src/main/cpp/Live2DModel.hpp',
    '''private:
    void SetupModel();''',
    '''private:
    /// 外部持续驱动参数（嘴型等），每帧 Update() 末尾重新应用
    Csm::csmMap<Csm::csmString, Csm::csmFloat32> _externalParams;

    void SetupModel();''',
    marker: '_externalParams',
  ),
  _Edit(
    'android/src/main/cpp/Live2DModel.cpp',
    '''    // Pose
    if (_pose)
        _pose->UpdateParameters(_model, deltaTime);

    _model->Update();
}''',
    '''    // Pose
    if (_pose)
        _pose->UpdateParameters(_model, deltaTime);

    // 外部持续驱动参数（嘴型等）必须在 _model->Update() **之前**应用：
    // 上面的 LoadParameters() 会重置参数、motion/expression 也会覆盖，
    // 而在 _model->Update() 之后设置就不再影响本帧顶点了
    for (Csm::csmMap<Csm::csmString, Csm::csmFloat32>::const_iterator it = _externalParams.Begin();
         it != _externalParams.End(); ++it)
    {
        const CubismId* id =
            CubismFramework::GetIdManager()->GetId(it->First.GetRawString());
        if (_model->GetParameterIndex(id) >= 0)
        {
            _model->SetParameterValue(id, it->Second);
        }
        else if (_lipSyncIds.GetSize() > 0)
        {
            // 参数名对不上（mao 是 ParamA、wanko 是 PARAM_MOUTH_OPEN_Y），
            // 回退到模型自己声明的 LipSync 组（model3.json 的 Groups.LipSync）
            for (Csm::csmUint32 i = 0; i < _lipSyncIds.GetSize(); i++)
            {
                _model->SetParameterValue(_lipSyncIds[i], it->Second);
            }
        }
    }

    _model->Update();
}''',
    marker: 'mao 是 ParamA',
  ),
  _Edit(
    'android/src/main/cpp/Live2DModel.cpp',
    '''void Live2DModel::Draw(const Csm::CubismMatrix44& matrix)''',
    '''void Live2DModel::SetExternalParameter(const Csm::csmChar* parameterId, Csm::csmFloat32 value)
{
    if (!parameterId) return;
    _externalParams[Csm::csmString(parameterId)] = value;
}

void Live2DModel::Draw(const Csm::CubismMatrix44& matrix)''',
    marker: 'SetExternalParameter(const Csm::csmChar* parameterId',
  ),
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    const char* id = env->GetStringUTFChars(parameterId, nullptr);
    view->model->SetParameterValue(id, value);
    env->ReleaseStringUTFChars(parameterId, id);''',
    '''    const char* id = env->GetStringUTFChars(parameterId, nullptr);
    // 用 SetExternalParameter：每帧 Update() 开头会 LoadParameters() 重置参数，
    // 直接 SetParameterValue 的值活不过一帧（嘴型永远是 0）
    view->model->SetExternalParameter(id, value);
    env->ReleaseStringUTFChars(parameterId, id);''',
    marker: '用 SetExternalParameter',
  ),

  // ---- 4.7 原生渲染：贴边紧凑模式（矩阵缩放）+ 触摸穿透 ----
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    bool                  surfaceNeedsInit = false;''',
    '''    bool                  surfaceNeedsInit = false;
    // 贴边时把模型在视图内缩小（0~1，1 = 正常）
    float                 renderScale      = 1.0f;''',
    marker: 'float                 renderScale',
  ),
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    const char* id = env->GetStringUTFChars(parameterId, nullptr);
    view->model->SetParameterValue(id, value);
    env->ReleaseStringUTFChars(parameterId, id);''',
    '''    const char* id = env->GetStringUTFChars(parameterId, nullptr);
    // 特殊参数名：贴边时把模型在视图内缩小（TextureView 不能做 transform，
    // 只能在渲染矩阵上缩）。复用 setParameter 通道，避免再加一套 JNI。
    if (std::string(id) == "__render_scale__")
    {
        view->renderScale = (value > 0.05f && value <= 1.0f) ? value : 1.0f;
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    view->model->SetParameterValue(id, value);
    env->ReleaseStringUTFChars(parameterId, id);''',
    marker: '__render_scale__',
  ),
  // 贴边紧凑缩放统一交给 6.4/6.6 的 ApplyViewportFit（叠 ScaleRelative +
  // TranslateRelative 到模型矩阵）。早先「在 draw 处缩投影矩阵」的做法
  // 会跟居中补偿互相打架，已废弃，故此处不再改 draw 代码块。
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
  // surfaceChanged 的投影不再改动（保留上游各向异性补偿）：ApplyViewportFit
  // 每帧都会重设投影 + 模型矩阵，这里无需单独干预。

  // ---- 6.2 Live2DModel 暴露 canvas 尺寸 ----
  _Edit(
    'android/src/main/cpp/Live2DModel.hpp',
    '''    bool IsLoaded() const { return _modelSetting != nullptr; }''',
    '''    bool IsLoaded() const { return _modelSetting != nullptr; }

    /// 取模型的 canvas 尺寸（模型空间）
    ///
    /// 用于按**长宽比**适配视口：canvas 尺寸决定模型的实际外框，
    /// 直接按容器宽高拉伸会把模型压扁。
    void GetCanvasSize(float& width, float& height) const;''',
    marker: 'GetCanvasSize',
  ),
  _Edit(
    'android/src/main/cpp/Live2DModel.cpp',
    '''void Live2DModel::SetExternalParameter(const Csm::csmChar* parameterId, Csm::csmFloat32 value)''',
    '''void Live2DModel::GetCanvasSize(float& width, float& height) const
{
    width = height = 0.0f;
    if (!_model) return;
    width = _model->GetCanvasWidth();
    height = _model->GetCanvasHeight();
}

void Live2DModel::SetExternalParameter(const Csm::csmChar* parameterId, Csm::csmFloat32 value)''',
    marker: 'void Live2DModel::GetCanvasSize',
  ),
  _Edit(
    'android/src/main/cpp/Live2DModel.hpp',
    '''    void GetCanvasSize(float& width, float& height) const;''',
    '''    void GetCanvasSize(float& width, float& height) const;

    /// 取模型**内容**（所有 drawable 顶点的并集）在模型空间的包围盒
    ///
    /// Live2D 的 canvas 四周留白很大（角色只占中间一部分），
    /// 按 canvas 适配会让角色在竖长的盒子里显得又细又长。
    /// 用 drawable 顶点算出的才是角色**本体**的范围。
    void GetContentBounds(
        float& minX, float& minY, float& maxX, float& maxY) const;''',
    marker: 'void GetContentBounds',
  ),
  _Edit(
    'android/src/main/cpp/Live2DModel.cpp',
    '''void Live2DModel::GetCanvasSize(float& width, float& height) const
{
    width = height = 0.0f;
    if (!_model) return;
    width = _model->GetCanvasWidth();
    height = _model->GetCanvasHeight();
}''',
    '''void Live2DModel::GetCanvasSize(float& width, float& height) const
{
    width = height = 0.0f;
    if (!_model) return;
    width = _model->GetCanvasWidth();
    height = _model->GetCanvasHeight();
}

void Live2DModel::GetContentBounds(
    float& minX, float& minY, float& maxX, float& maxY) const
{
    minX = minY = 1e9f;
    maxX = maxY = -1e9f;
    if (!_model) return;
    const csmInt32 drawableCount = _model->GetDrawableCount();
    for (csmInt32 d = 0; d < drawableCount; d++)
    {
        const csmInt32 vCount = _model->GetDrawableVertexCount(d);
        if (vCount <= 0) continue;
        // GetDrawableVertices 返回扁平数组：每顶点 x, y 两个 float
        const csmFloat32* verts = _model->GetDrawableVertices(d);
        if (!verts) continue;
        for (csmInt32 i = 0; i < vCount; i++)
        {
            const float x = verts[i * 2];
            const float y = verts[i * 2 + 1];
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
        }
    }
}''',
    marker: 'void Live2DModel::GetContentBounds',
  ),

  // ---- 6.3 内容边界改成「缓存 + 每帧刷新」 ----
  //
  // 关键：drawable 顶点是 `_model->Update()` 写进去的，加载完那一帧
  // 还没 Update 时顶点是空的 —— 边界必须等 Update 之后才算。
  _Edit(
    'android/src/main/cpp/Live2DModel.hpp',
    '''    void GetContentBounds(
        float& minX, float& minY, float& maxX, float& maxY) const;''',
    '''    void GetContentBounds(
        float& minX, float& minY, float& maxX, float& maxY) const;

    /// 重新计算内容边界（每帧 Update 之后调用）
    void RefreshContentBounds();''',
    marker: 'void RefreshContentBounds',
  ),
  _Edit(
    'android/src/main/cpp/Live2DModel.hpp',
    '''    Csm::csmMap<Csm::csmString, Csm::csmFloat32> _externalParams;''',
    '''    Csm::csmMap<Csm::csmString, Csm::csmFloat32> _externalParams;

    /// 内容边界缓存（模型空间），每帧 Update 之后刷新
    float _contentMinX = 0.0f;
    float _contentMinY = 0.0f;
    float _contentMaxX = 0.0f;
    float _contentMaxY = 0.0f;
    bool _contentBoundsValid = false;''',
    marker: '_contentBoundsValid',
  ),
  _Edit(
    'android/src/main/cpp/Live2DModel.cpp',
    '''void Live2DModel::GetContentBounds(
    float& minX, float& minY, float& maxX, float& maxY) const
{
    minX = minY = 1e9f;
    maxX = maxY = -1e9f;
    if (!_model) return;
    const csmInt32 drawableCount = _model->GetDrawableCount();
    for (csmInt32 d = 0; d < drawableCount; d++)
    {
        const csmInt32 vCount = _model->GetDrawableVertexCount(d);
        if (vCount <= 0) continue;
        // GetDrawableVertices 返回扁平数组：每顶点 x, y 两个 float
        const csmFloat32* verts = _model->GetDrawableVertices(d);
        if (!verts) continue;
        for (csmInt32 i = 0; i < vCount; i++)
        {
            const float x = verts[i * 2];
            const float y = verts[i * 2 + 1];
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
        }
    }
}''',
    '''void Live2DModel::RefreshContentBounds()
{
    if (!_model) return;
    float minX = 1e9f, minY = 1e9f, maxX = -1e9f, maxY = -1e9f;
    const csmInt32 drawableCount = _model->GetDrawableCount();
    for (csmInt32 d = 0; d < drawableCount; d++)
    {
        const csmInt32 vCount = _model->GetDrawableVertexCount(d);
        if (vCount <= 0) continue;
        const csmFloat32* verts = _model->GetDrawableVertices(d);
        if (!verts) continue;
        for (csmInt32 i = 0; i < vCount; i++)
        {
            const float x = verts[i * 2];
            const float y = verts[i * 2 + 1];
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
        }
    }
    if (maxX > minX && maxY > minY)
    {
        _contentMinX = minX;
        _contentMinY = minY;
        _contentMaxX = maxX;
        _contentMaxY = maxY;
        _contentBoundsValid = true;
    }
}

void Live2DModel::GetContentBounds(
    float& minX, float& minY, float& maxX, float& maxY) const
{
    minX = _contentMinX;
    minY = _contentMinY;
    maxX = _contentMaxX;
    maxY = _contentMaxY;
}''',
    marker: 'void Live2DModel::RefreshContentBounds',
  ),
  _Edit(
    'android/src/main/cpp/Live2DModel.cpp',
    '''    _model->Update();
}''',
    '''    _model->Update();

    // 顶点数据是 _model->Update() 写进去的，所以内容边界必须**之后**才算
    // （加载完那一帧还没 Update 时顶点是空的，边界会算成 0）
    RefreshContentBounds();
}''',
    marker: 'RefreshContentBounds();',
  ),

  // ---- 6.4 每帧按角色本体适配视口（比例 + 居中） ----
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''static bool ReloadModelInternal(Live2DView* view, const char* dir, const char* file)''',
    '''static void ApplyViewportFit(Live2DView* view)
{
    if (!view || !view->model || !view->model->IsLoaded()) return;

    // ---- 投影矩阵：每帧重设，做各向异性补偿 ----
    //
    // 裁剪空间是正方形 [-1,1]²，视口是长方形，NDC -> 屏幕的映射本身各向异性。
    // 要让模型在屏幕上**不变形**，必须满足 P_x * M_x * W == P_y * M_y * H。
    // 竖容器取 P_x = H/W、P_y = 1，配合**等比**的模型矩阵即恒成立。
    // （用单位矩阵的话条件退化成 W == H，竖屏下模型被纵向拉长。）
    view->projection.LoadIdentity();
    if (view->width > 0 && view->height > 0)
    {
        if (view->width > view->height)
        {
            // 横容器：y 方向拉伸
            view->projection.Scale(
                1.0f, (float)view->width / (float)view->height);
        }
        else
        {
            // 竖容器：x 方向拉伸
            view->projection.Scale(
                (float)view->height / (float)view->width, 1.0f);
        }
    }

    // ---- 模型矩阵：按 **canvas** 适配（Cubism 官方标准做法）----
    //
    // SetHeight / SetWidth 内部 scaleX == scaleY（等比，不会变形），
    // 且以 canvas 中心为原点（位置自然在视口中间）。
    // 视口与 canvas 的宽高比不一致时**允许裁切**（官方行为）——
    // 不再依赖 drawable 顶点算「角色本体」边界（那个外框含背景/遮罩，
    // 量不准，会让模型跑偏或缩成一条腿）。
    float cw = 0.0f, ch = 0.0f;
    view->model->GetCanvasSize(cw, ch);
    if (cw <= 0.0f || ch <= 0.0f) return;
    const float modelAspect = cw / ch;
    const float viewAspect = (view->width > 0 && view->height > 0)
        ? (float)view->width / (float)view->height
        : 1.0f;
    auto* mm = view->model->GetModelMatrix();
    if (!mm) return;
    // SetHeight 内部是 Scale()（相对累乘）-> 每帧先重置，否则缩放指数级累积
    mm->LoadIdentity();
    if (viewAspect > modelAspect)
    {
        // 视口更宽 -> 按 canvas 高度填满（两侧可能留白或裁切）
        mm->SetHeight(2.0f);
    }
    else
    {
        // 视口更高 -> 按 canvas 宽度填满（上下可能留白或裁切）
        mm->SetWidth(2.0f);
    }
}''',
    marker: 'static void ApplyViewportFit(Live2DView* view)',
  ),
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    view->model->SetupTextures();
    L2DLOG("SetupTextures done");''',
    '''    view->model->SetupTextures();
    L2DLOG("SetupTextures done");
    // 按角色本体适配（见 ApplyViewportFit）
    ApplyViewportFit(view);''',
    marker: '按角色本体适配（见 ApplyViewportFit）',
  ),
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''        view->model->Update();
        CubismMatrix44 mvp = view->projection;''',
    '''        view->model->Update();
        // Update() 之后内容边界才是最新的 -> 每帧重新适配一次
        ApplyViewportFit(view);
        CubismMatrix44 mvp = view->projection;''',
    marker: 'Update() 之后内容边界才是最新的',
  ),
  // ---- 6.5 原生侧也按「角色本体」适配（需要 WebView 量到的边界） ----
  //
  // WebView 侧用 model.getLocalBounds() 拿到角色**本体**的范围（canvas 四周
  // 留白很大，只按 canvas 适配的话模型会又小又偏，和 WebView 对不上）。
  // Cubism Native 没有等价 API，所以由 Dart 侧把归一化矩形传进来。
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    float                 renderScale      = 1.0f;''',
    '''    float                 renderScale      = 1.0f;
    // 角色**本体**在 canvas 里的归一化矩形（中心x, 中心y, 宽, 高）
    float                 fitBounds[4]    = {0.0f, 0.0f, 0.0f, 0.0f};
    bool                  fitBoundsValid  = false;''',
    marker: 'fitBoundsValid',
  ),
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    Live2DView* view = AsView(handle);
    if (!view; !view->model; !view->model->IsLoaded()) return;
    const char* id = env->GetStringUTFChars(parameterId, nullptr);''',
    '''    Live2DView* view = AsView(handle);
    if (!view) return;
    const char* id = env->GetStringUTFChars(parameterId, nullptr);
    // 特殊参数要在「模型是否加载」之前处理 —— 边界比模型先到
    if (std::string(id) == "__fit_cx__")
    {
        view->fitBounds[0] = value;
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    if (std::string(id) == "__fit_cy__")
    {
        view->fitBounds[1] = value;
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    if (std::string(id) == "__fit_w__")
    {
        view->fitBounds[2] = value;
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    if (std::string(id) == "__fit_h__")
    {
        view->fitBounds[3] = value;
        view->fitBoundsValid = (value > 0.0f);
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    if (!view->model; !view->model->IsLoaded())
    {
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }''',
    marker: '__fit_cx__',
  ),
  // ---- 6.5 展开适配保持 canvas 不变（本体边界仅存字段，供需要时使用）----
  //
  // WebView 侧量到的 fitBounds 已由上面两处 edit（结构体字段 + __fit_*__
  // 分支）存到 view 里。展开态适配仍按 canvas（与现网行为一致）；
  // 贴边紧凑模式在 6.6 里按 canvas 缩到窄条（与 WebView 同语义）。

  // ---- 6.6 原生渲染：贴边紧凑模式的「视图内缩小 + 贴右上角」 ----
  //
  // 浮窗贴边时裁剪框只有窄条（约 112x152），但平台视图**不能 resize**
  // （重建 surface 会闪断）。所以和 WebView 侧 setCompact 同一思路：
  // 视图保持展开尺寸，C++ 把角色本体缩到窄条对应的 NDC 范围并贴到视图
  // 右上角，Flutter 侧裁剪露出的正是右上角 —— 看到的就是完整缩小版模型。
  //
  // 窄条尺寸由 Dart 换算成 NDC 半宽 / 高度占比传进来（C++ 不用关心 dpr）。
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    CubismMatrix44        projection;''',
    '''    // 贴边紧凑模式：启用标志 + 窄条在 NDC 里的半宽 / 全高占比
    // （Dart 按挂件尺寸 / 展开视图尺寸算好传进来）
    bool                  compactEnable   = false;
    float                 compactHalfW    = 0.0f;
    float                 compactHRatio   = 0.0f;
    CubismMatrix44        projection;''',
    // marker 要够特异：，ApplyViewportFit / setParameter 里也引用了 compactEnable，
    // 所以上面那个单词不能当标记（会被误判成已打过）。
    marker: 'compactEnable   = false;',
  ),
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    if (std::string(id) == "__render_scale__")''',
    '''    // 贴边紧凑模式的三个特殊参数：开关和尺寸可能在模型就绪前就下发
    if (std::string(id) == "__compact_enable__")
    {
        const bool on = (value > 0.5f);
        if (on != view->compactEnable)
        {
            view->compactEnable = on;
            __android_log_print(ANDROID_LOG_INFO, "Live2DPlugin",
                                "compact mode -> %d", on ? 1 : 0);
        }
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    if (std::string(id) == "__compact_half_w__")
    {
        view->compactHalfW  = (value > 0.0f && value <= 1.0f) ? value : 0.0f;
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    if (std::string(id) == "__compact_h_ratio__")
    {
        view->compactHRatio = (value > 0.0f && value < 1.0f) ? value : 0.0f;
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    if (std::string(id) == "__render_scale__")''',
    marker: '__compact_half_w__',
  ),
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''static void ApplyViewportFit(Live2DView* view)
{
    if (!view || !view->model || !view->model->IsLoaded()) return;

    // ---- 投影矩阵：每帧重设，做各向异性补偿 ----
    //
    // 裁剪空间是正方形 [-1,1]²，视口是长方形，NDC -> 屏幕的映射本身各向异性。
    // 要让模型在屏幕上**不变形**，必须满足 P_x * M_x * W == P_y * M_y * H。
    // 竖容器取 P_x = H/W、P_y = 1，配合**等比**的模型矩阵即恒成立。
    // （用单位矩阵的话条件退化成 W == H，竖屏下模型被纵向拉长。）
    view->projection.LoadIdentity();
    if (view->width > 0 && view->height > 0)
    {
        if (view->width > view->height)
        {
            // 横容器：y 方向拉伸
            view->projection.Scale(
                1.0f, (float)view->width / (float)view->height);
        }
        else
        {
            // 竖容器：x 方向拉伸
            view->projection.Scale(
                (float)view->height / (float)view->width, 1.0f);
        }
    }

    // ---- 模型矩阵：按 **canvas** 适配（Cubism 官方标准做法）----
    //
    // SetHeight / SetWidth 内部 scaleX == scaleY（等比，不会变形），
    // 且以 canvas 中心为原点（位置自然在视口中间）。
    // 视口与 canvas 的宽高比不一致时**允许裁切**（官方行为）——
    // 不再依赖 drawable 顶点算「角色本体」边界（那个外框含背景/遮罩，
    // 量不准，会让模型跑偏或缩成一条腿）。
    float cw = 0.0f, ch = 0.0f;
    view->model->GetCanvasSize(cw, ch);
    if (cw <= 0.0f || ch <= 0.0f) return;
    const float modelAspect = cw / ch;
    const float viewAspect = (view->width > 0 && view->height > 0)
        ? (float)view->width / (float)view->height
        : 1.0f;
    auto* mm = view->model->GetModelMatrix();
    if (!mm) return;
    // SetHeight 内部是 Scale()（相对累乘）-> 每帧先重置，否则缩放指数级累积
    mm->LoadIdentity();
    if (viewAspect > modelAspect)
    {
        // 视口更宽 -> 按 canvas 高度填满（两侧可能留白或裁切）
        mm->SetHeight(2.0f);
    }
    else
    {
        // 视口更高 -> 按 canvas 宽度填满（上下可能留白或裁切）
        mm->SetWidth(2.0f);
    }
}''',
    '''static void ApplyViewportFit(Live2DView* view)
{
    if (!view || !view->model || !view->model->IsLoaded()) return;

    // ---- 投影矩阵：每帧重设，做各向异性补偿 ----
    //
    // 裁剪空间是正方形 [-1,1]²，视口是长方形，NDC -> 屏幕的映射本身各向异性。
    // 要让模型在屏幕上**不变形**，必须满足 P_x * M_x * W == P_y * M_y * H。
    // 竖容器取 P_x = H/W、P_y = 1，配合**等比**的模型矩阵即恒成立。
    float px = 1.0f, py = 1.0f;
    view->projection.LoadIdentity();
    if (view->width > 0 && view->height > 0)
    {
        if (view->width > view->height)
        {
            // 横容器：y 方向拉伸
            py = (float)view->width / (float)view->height;
            view->projection.Scale(1.0f, py);
        }
        else
        {
            // 竖容器：x 方向拉伸
            px = (float)view->height / (float)view->width;
            view->projection.Scale(px, 1.0f);
        }
    }

    // ---- 模型矩阵：按角色**本体**（drawable 顶点并集）做 contain 适配 ----
    //
    // 之前按 canvas 且用 cover（填满视口）语义：canvas 四周留白大、各模型
    // 不一，填满竖容器时上下会被裁（展开态切头/脚，贴边腿部露不全）。
    // 改成 contain：把**本体**完整放入目标区，绝不裁切（与 WebView 侧同语义）。
    auto* mm = view->model->GetModelMatrix();
    if (!mm) return;

    float cw = 0.0f, ch = 0.0f;
    view->model->GetCanvasSize(cw, ch);
    float bminX = 0.0f, bminY = 0.0f, bmaxX = 0.0f, bmaxY = 0.0f;
    view->model->GetContentBounds(bminX, bminY, bmaxX, bmaxY);
    float fw = bmaxX - bminX;      // 本体宽（模型空间）
    float fh = bmaxY - bminY;      // 本体高
    float fcx = (bminX + bmaxX) * 0.5f;   // 本体中心
    float fcy = (bminY + bmaxY) * 0.5f;
    if (fw <= 0.0f || fh <= 0.0f)
    {
        // 本体边界还没算出来 -> 退回 canvas（居中）
        if (cw <= 0.0f || ch <= 0.0f) return;
        fw = cw; fh = ch; fcx = 0.0f; fcy = 0.0f;
    }

    // 目标 = 整个视口居中、等比 contain 完整放入本体。
    //
    // 贴边收起不再靠「把模型缩到窄条 + 贴角 + Flutter 裁角」——那套依赖平台视图
    // 出屏溢出的裁剪映射，在 Android 混合合成下左右不对称、且角色贴到出屏交界线
    // 会被裁脚。改由 Flutter 直接把平台视图 resize 到窄条尺寸，这里对任意视口
    // 只做「居中 contain」，左右贴边天然对称、身体完整。margin 留余量吸收超出
    // 顶点的靴子/描边像素（顶点并集不含贴图外溢）。
    const float margin = 0.92f;
    const float s = fminf(2.0f / (px * fw), 2.0f / (py * fh)) * margin;

    mm->LoadIdentity();
    mm->ScaleRelative(s, s);
    // 本体中心 -> 视口中心 (0,0)：clip = proj*(s*fc + t) = 0 => t = -s*fc
    mm->TranslateRelative(-s * fcx, -s * fcy);
}''',
    marker: '整个视口居中、等比 contain',
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
      stderr.writeln('✗ 找不到要替换的代码（插件版本可能变了）: ${edit.file} / marker=${edit.marker}');
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
