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
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''        view->model->Update();
        CubismMatrix44 mvp = view->projection;
        view->model->Draw(mvp);''',
    '''        view->model->Update();
        CubismMatrix44 mvp = view->projection;
        // 贴边紧凑模式：把模型等比缩小（投影空间），模型保持在视图中央，
        // Flutter 侧裁剪露出的正是中央，于是能完整看到缩小版模型。
        if (view->renderScale < 1.0f)
        {
            const float s = view->renderScale;
        }
        view->model->Draw(mvp);''',
    marker: '必须用 **ScaleRelative**（相对缩放）而不是 Scale',
  ),
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
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    view->projection.LoadIdentity();
    if (view->width > view->height)
    {
        float ratio = static_cast<float>(view->height) / static_cast<float>(view->width);
        view->projection.Scale(ratio, 1.0f);
    }
    else
    {
        float ratio = static_cast<float>(view->width) / static_cast<float>(view->height);
        view->projection.Scale(1.0f, ratio);
    }''',
    '''    // 投影保持**单位矩阵**：比例由模型矩阵（SetHeight）保证。
    // 之前这里对竖容器做 Scale(1, w/h)，把 y 方向压缩了 ——
    // 模型虽然能填满视口，但**长宽比被破坏**（看起来被压扁）。
    view->projection.LoadIdentity();''',
    marker: '投影保持**单位矩阵**',
  ),

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

    // 投影矩阵**每帧重设**（不依赖 nativeOnSurfaceChanged 的回调时机 ——
    // surface 尺寸没变时那个回调不会来，投影就会一直是初始值）：
    //
    // 裁剪空间是正方形 [-1,1]²，视口是长方形，NDC -> 屏幕的映射本身各向异性。
    // 要让模型在屏幕上**不变形**，必须满足 P_x * M_x * W == P_y * M_y * H。
    // 竖容器取 P_x = H/W、P_y = 1，配合**等比**的模型矩阵（M_x == M_y）即恒成立。
    // （之前用单位矩阵，条件退化成 W == H —— 竖屏下不成立，模型被纵向拉长，
    //  实测宽高比只有 WebView 侧的一半。）
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

    // Cubism 官方标准适配：按 canvas 宽高比与视口宽高比比较，
    // 选 SetHeight(2.0) 或 SetWidth(2.0)。
    //   - 内部 scaleX = scaleY（等比，不会拉伸）
    //   - 以 canvas 中心为原点（位置自然在视口中间）
    //
    // ⚠️ 不用 drawable 顶点算「角色本体」边界：那个外框含背景/遮罩，
    // 比角色本体大得多 —— 实测模型会缩成一半大、还偏出角色盒。
    // WebView 侧用的是 model.getLocalBounds()（真正的角色本体边界），
    // Cubism Native 没有等价 API，所以原生侧比 WebView 略小一点。
    float cw = 0.0f, ch = 0.0f;
    view->model->GetCanvasSize(cw, ch);
    if (cw <= 0.0f || ch <= 0.0f) return;
    const float modelAspect = cw / ch;
    const float viewAspect = (view->width > 0 && view->height > 0)
        ? (float)view->width / (float)view->height
        : 1.0f;
    auto* mm = view->model->GetModelMatrix();
    if (!mm) return;
    // 有「角色本体」边界（WebView 侧量到的）时，按**本体**适配 ——
    // 这样原生和 WebView 的效果一致（角色填满盒子、位置居中）。
    if (view->fitBoundsValid)
    {
        const float bodyW = cw * view->fitBounds[2];   // 本体在模型空间的宽
        const float bodyH = ch * view->fitBounds[3];   // 本体在模型空间的高
        // 合理性保护：本体不可能小于 canvas 的 10%，否则说明边界数据有误
        // （WebView 侧量出来的），宁可退回按 canvas 适配也别把模型缩成一条腿
        if (bodyW > cw * 0.05f && bodyH > ch * 0.1f &&
            bodyW < cw && bodyH < ch)
        {
            // 投影对 x 方向做了各向异性拉伸（P_x），本体投影后的横向范围
            // 是 bodyW * s * P_x，必须留在裁剪空间 [-1,1] 内，否则会被裁掉两侧。
            const float px = (view->width > view->height && view->height > 0)
                ? 1.0f
                : (view->width > 0
                       ? (float)view->height / (float)view->width
                       : 1.0f);
            // 贴边紧凑模式：在**模型矩阵**里再缩（renderScale），而不是缩放投影
            // —— 投影缩放会和 SetCenterPosition 的居中补偿互相打架
            // （模型会跑到角落、只露出一部分）。
            const float rs = (view->renderScale < 1.0f) ? view->renderScale : 1.0f;
            const float s = fminf(2.0f / bodyH, 2.0f / (bodyW * px)) * rs;
            // ⚠️ CubismModelMatrix::SetHeight 内部是 **Scale()（相对累乘）**，
            // 每帧调用会让缩放**指数级累积**（模型缩成一条腿）。
            // 所以每帧先把模型矩阵重置为 identity，再设缩放。
            mm->LoadIdentity();
            mm->SetHeight(ch * s);
            // 让**本体中心**落在视口原点：
            //   SetCenterPosition 移动的是 **canvas 中心**，
            //   而 fitBounds 给的是本体中心（归一化到 canvas 尺寸），
            //   两者相差 canvas 的一半 —— 必须减掉 0.5，
            //   否则模型会整体偏移半屏（贴边时只露出下半部分）。
            mm->SetCenterPosition(
                -(cw * (view->fitBounds[0] - 0.5f)) * s,
                -(ch * (view->fitBounds[1] - 0.5f)) * s);
            return;
        }
    }

    // 没有本体边界时退化成按 canvas 适配（位置由 Cubism 保证居中）
    const float rs2 = (view->renderScale < 1.0f) ? view->renderScale : 1.0f;
    mm->LoadIdentity();
    if (viewAspect > modelAspect)
    {
        // 视口更宽 -> 按 canvas 高度填满（两侧可能留白）
        mm->SetHeight(2.0f * rs2);
    }
    else
    {
        // 视口更高 -> 按 canvas 宽度填满（上下可能留白）
        mm->SetWidth(2.0f * rs2);
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
  _Edit(
    'android/src/main/cpp/live2d_flutter.cpp',
    '''    auto* mm = view->model->GetModelMatrix();
    if (!mm) return;
    if (viewAspect > modelAspect)''',
    '''    auto* mm = view->model->GetModelMatrix();
    if (!mm) return;
    // 有「角色本体」边界时按**本体**适配（和 WebView 一致）
    if (view->fitBoundsValid)
    {
        const float bodyW = cw * view->fitBounds[2];
        const float bodyH = ch * view->fitBounds[3];
        if (bodyW > 0.0f; bodyH > 0.0f)
        {
            const float s = fminf(2.0f / bodyW, 2.0f / bodyH);
            mm->SetHeight(ch * s);
            mm->SetCenterPosition(
                -(view->fitBounds[0] * cw) * s,
                -(view->fitBounds[1] * ch) * s);
            return;
        }
    }
    if (viewAspect > modelAspect)''',
    marker: '有「角色本体」边界',
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
