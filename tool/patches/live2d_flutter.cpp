/**
 * JNI bridge between Flutter (Kotlin) and the Live2D Cubism SDK.
 *
 * Per-view design: every Live2DPlatformView on the Kotlin side calls
 * nativeCreateView() once to get an opaque jlong handle to a Live2DView
 * instance allocated on the heap here. All subsequent calls take that handle
 * so multiple views can coexist without sharing global mutable state.
 *
 * Kotlin class: com.linh18nd.flutter_live2d.Live2DBridge
 */

#include <jni.h>
#include <GLES2/gl2.h>
#include <android/log.h>
#include <cstring>
#include <string>
#define L2DLOG(...) __android_log_print(ANDROID_LOG_INFO, "Live2DPlugin", __VA_ARGS__)
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <CubismFramework.hpp>
#include <Math/CubismMatrix44.hpp>
#include <Math/CubismViewMatrix.hpp>
#include <Rendering/OpenGL/CubismRenderer_OpenGLES2.hpp>

#include "Live2DAllocator.hpp"
#include "Live2DPal.hpp"
#include "Live2DTextureManager.hpp"
#include "Live2DModel.hpp"

using namespace Csm;

// ---------------------------------------------------------------------------
// Per-view state. Lives behind an opaque jlong handle on the Kotlin side.
// ---------------------------------------------------------------------------
struct Live2DView
{
    Live2DTextureManager* textureManager = nullptr;
    Live2DModel*          model           = nullptr;
    int                   width           = 0;
    int                   height          = 0;
    bool                  surfaceNeedsInit = false;
    // 贴边时把模型在视图内缩小（0~1，1 = 正常）
    float                 renderScale      = 1.0f;
    // 角色**本体**在 canvas 里的归一化矩形（中心x, 中心y, 宽, 高）
    // 由 Dart 侧用 WebView 量到的 getLocalBounds() 换算后传进来。
    // 原生侧没有 getLocalBounds() 的等价 API —— 只按 canvas 尺寸适配的话，
    // canvas 四周留白会让模型显得又小又偏（和 WebView 对不上）。
    float                 fitBounds[4]    = {0.0f, 0.0f, 0.0f, 0.0f};
    // 模型放大系数（1.0 = 按自动适配结果显示）
    float                 renderZoom       = 1.0f;
    bool                  fitBoundsValid  = false;
    // CubismFramework 必须在**有 GL context** 时才初始化（它会生成 shader program），
    // 所以延迟到 nativeOnSurfaceCreated（render hub 线程，已 eglMakeCurrent）
    bool                  frameworkRetained = false;
    // 贴边紧凑模式：启用标志 + 窄条在 NDC 里的半宽 / 全高占比
    // （Dart 按挂件尺寸 / 展开视图尺寸算好传进来）
    bool                  compactEnable   = false;
    float                 compactHalfW    = 0.0f;
    float                 compactHRatio   = 0.0f;
    CubismMatrix44        projection;
};

static inline Live2DView* AsView(jlong handle)
{
    return reinterpret_cast<Live2DView*>(static_cast<intptr_t>(handle));
}

// ---------------------------------------------------------------------------
// Framework lifecycle (refcounted across views)
// ---------------------------------------------------------------------------
static Live2DAllocator         g_allocator;
static CubismFramework::Option g_options;
static int                     g_frameworkRefCount = 0;

static void LogFunction(const char* /*message*/) {}

static void FrameworkRetain()
{
    if (g_frameworkRefCount++ == 0)
    {
        g_options.LogFunction          = LogFunction;
        g_options.LoggingLevel         = CubismFramework::Option::LogLevel_Verbose;
        g_options.LoadFileFunction     = Live2DPal::LoadFileAsBytes;
        g_options.ReleaseBytesFunction = Live2DPal::ReleaseBytes;

        CubismFramework::StartUp(&g_allocator, &g_options);
        CubismFramework::Initialize();
    }
}

static void FrameworkRelease()
{
    if (--g_frameworkRefCount <= 0)
    {
        g_frameworkRefCount = 0;
        CubismFramework::Dispose();
    }
}

static void ConfigureRendererForStability(Live2DModel* model)
{
    if (!model) return;
    auto* renderer =
        model->GetRenderer<Live2D::Cubism::Framework::Rendering::CubismRenderer_OpenGLES2>();
    if (!renderer) return;

    // High-precision mask becomes unstable under repeated surface lifecycle /
    // resize in this Flutter PlatformView setup. Force normal mask path.
    renderer->UseHighPrecisionMask(false);
}

/// 按**角色本体**（drawable 顶点并集）把模型适配到视口
///
/// Live2D 的 canvas 四周留白很大，若只按 canvas 适配，角色在竖长的
/// 盒子里会被拉得很长（宽度填满、高度溢出视口）。
/// 投影是单位矩阵（视口 x,y ∈ [-1,1]），所以让内容边界完整放入即可：
///   缩放系数 s = min(2/内容宽, 2/内容高)
///   SetHeight 等比缩放（内部 scaleX = scaleY，不会变形）
///   SetCenterPosition 把**内容中心**移到视口中心
///
/// 内容边界由 Live2DModel 在每帧 Update() 之后缓存（那时顶点才有效），
/// 所以这个函数要**每帧**调用一次。
static void ApplyViewportFit(Live2DView* view)
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

    // ---- 模型矩阵：按**角色本体**做居中 contain 适配 ----
    //
    // 本体的来源有优先级：
    //   1. `__fit_*__`：WebView 侧用 `model.getLocalBounds()` 量出的
    //      **真正的角色本体**（四个分量归一化到 canvas）
    //   2. canvas 兜底：位置正确、角色略小
    //
    // ⚠️ **不要用 drawable 顶点（GetContentBounds）当本体边界**：
    // 那个外框含背景与遮罩，对 mao 这类模型会大出好几倍，
    // 于是缩放系数被算得极小 —— 实测「mao 在原生下比 WebView 小几倍」。
    auto* mm = view->model->GetModelMatrix();
    if (!mm) return;

    float cw = 0.0f, ch = 0.0f;
    view->model->GetCanvasSize(cw, ch);
    if (cw <= 0.0f || ch <= 0.0f) return;

    float fw, fh, fcx, fcy;
    if (view->fitBoundsValid)
    {
        // fitBounds = { 中心x, 中心y, 宽, 高 }，都归一化到 canvas 的 0~1
        fw = cw * view->fitBounds[2];
        fh = ch * view->fitBounds[3];
        // 模型空间以 canvas 中心为原点 -> 减 0.5 再乘尺寸
        fcx = (view->fitBounds[0] - 0.5f) * cw;
        fcy = (view->fitBounds[1] - 0.5f) * ch;
    }
    else
    {
        fw = cw;
        fh = ch;
        fcx = 0.0f;
        fcy = 0.0f;
    }
    if (fw <= 0.0f || fh <= 0.0f) return;

    // 目标 = 整个视口居中、等比 contain 完整放入本体。
    //
    // 贴边收起不再靠「把模型缩到窄条 + 贴角 + Flutter 裁角」——那套依赖平台视图
    // 出屏溢出的裁剪映射，在 Android 混合合成下左右不对称、且角色贴到出屏交界线
    // 会被裁脚。改由 Flutter 直接把平台视图 resize 到窄条尺寸，这里对任意视口
    // 只做「居中 contain」，左右贴边天然对称、身体完整。margin 留余量吸收超出
    // 顶点的靴子/描边像素（顶点并集不含贴图外溢）。
    const float margin = 0.92f;
    const float s = fminf(2.0f / (px * fw), 2.0f / (py * fh)) * margin * view->renderZoom;

    mm->LoadIdentity();
    mm->ScaleRelative(s, s);
    // 本体中心 -> 视口中心 (0,0)：clip = proj*(s*fc + t) = 0 => t = -s*fc
    mm->TranslateRelative(-s * fcx, -s * fcy);
}static bool ReloadModelInternal(Live2DView* view, const char* dir, const char* file)
{
    if (!view || !dir || !file) return false;
    if (view->width <= 0 || view->height <= 0)
    {
        L2DLOG("ReloadModel ABORT: viewSize=%dx%d", view->width, view->height);
        return false;
    }
    if (!view->textureManager) view->textureManager = new Live2DTextureManager();

    L2DLOG("ReloadModel dir=%s file=%s viewSize=%dx%d", dir, file, view->width, view->height);

    delete view->model;
    view->model = new Live2DModel(view->textureManager);
    view->model->LoadAssets(dir, file);
    L2DLOG("LoadAssets done, IsLoaded=%d", view->model->IsLoaded() ? 1 : 0);
    if (!view->model->IsLoaded())
    {
        delete view->model;
        view->model = nullptr;
        return false;
    }

    view->model->CreateRenderer(view->width, view->height);
    L2DLOG("CreateRenderer done");
    ConfigureRendererForStability(view->model);
    view->model->SetupTextures();
    L2DLOG("SetupTextures done");
    // 按角色本体适配（见 ApplyViewportFit）
    ApplyViewportFit(view);

    return true;
}

extern "C" {

// ---------------------------------------------------------------------------
// JNI: global setup
// ---------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeSetAssetManager(JNIEnv* env, jclass,
    jobject assetManager)
{
    AAssetManager* mgr = AAssetManager_fromJava(env, assetManager);
    Live2DPal::SetAssetManager(mgr);
}

// ---------------------------------------------------------------------------
// JNI: per-view lifecycle
// ---------------------------------------------------------------------------

JNIEXPORT jlong JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeCreateView(JNIEnv*, jclass)
{
    // 注意：这里**不能**初始化 CubismFramework！
    // nativeCreateView 是在 Android 主线程调用的，此时没有 current EGL context，
    // 而 CubismFramework::Initialize() 内部会 CreateRenderer → 生成 OpenGL shader
    // program，没有 context 时全部失败，之后每帧 glUniform* 都会报
    // GL_INVALID_OPERATION，表现为「模型加载成功但画面永远是空白」。
    // 真正的初始化放在 nativeOnSurfaceCreated（render hub 线程，已 eglMakeCurrent）。
    Live2DView* view = new Live2DView();
    return static_cast<jlong>(reinterpret_cast<intptr_t>(view));
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeDestroyView(JNIEnv*, jclass, jlong handle)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    delete view->model;
    if (view->textureManager) view->textureManager->ReleaseTextures();
    delete view->textureManager;
    const bool retained = view->frameworkRetained;
    delete view;

    // 只有真的在 surface created 时 retain 过，才需要 release（配对）
    if (retained)
    {
        FrameworkRelease();
    }
}

// ---------------------------------------------------------------------------
// JNI: GL surface callbacks
// ---------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnSurfaceCreated(JNIEnv*, jclass,
    jlong handle)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    view->surfaceNeedsInit = true;

    // 这里在 render hub 线程上执行，EGL context 已经 current —— 是唯一安全的
    // 初始化 CubismFramework（含 shader program）的时机。
    if (!view->frameworkRetained)
    {
        FrameworkRetain();
        view->frameworkRetained = true;
        L2DLOG("FrameworkRetain on surface created (GL context ready)");
    }

    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    // GL textures and renderer are tied to the old context which is now gone.
    // Drop them so they get recreated on the next loadModel.
    delete view->model;
    view->model = nullptr;
    if (view->textureManager) view->textureManager->ReleaseTextures();
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnSurfaceDestroyed(JNIEnv*, jclass,
    jlong handle)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    delete view->model;
    view->model = nullptr;
    if (view->textureManager) view->textureManager->ReleaseTextures();

    view->surfaceNeedsInit = false;
    view->width = 0;
    view->height = 0;
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnSurfaceChanged(JNIEnv*, jclass,
    jlong handle, jint width, jint height)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    view->width = width;
    view->height = height;
    glViewport(0, 0, view->width, view->height);

    // 投影矩阵（Cubism 官方写法）：**各向异性补偿**，让模型在屏幕上等比。
    //
    // 裁剪空间是正方形 [-1,1]²，而视口是长方形，NDC -> 屏幕的映射本身
    // 就是各向异性的。所以要让模型在屏幕上**不变形**，必须满足
    //     P_x * M_x * W == P_y * M_y * H
    // 竖容器取 P_x = H/W、P_y = 1，配合**等比**的模型矩阵（M_x == M_y）
    // 就恒成立。之前这里用单位矩阵（P_x = P_y = 1），条件退化成
    // W == H —— 竖屏下不成立，模型被纵向拉长（实测宽高比只有 WebView 的一半）。
    view->projection.LoadIdentity();
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

    if (view->surfaceNeedsInit)
    {
        view->surfaceNeedsInit = false;
        return;
    }

    if (view->model && view->model->IsLoaded())
    {
        // 与 ReloadModelInternal 保持一致（见 ApplyViewportFit）
        ApplyViewportFit(view);
}
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnDrawFrame(JNIEnv*, jclass, jlong handle)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    Live2DPal::UpdateTime();

    glViewport(0, 0, view->width, view->height);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    // 只在真的发生 GL 错误时打日志（每帧检查但不刷屏）。
    // 正常渲染时 glGetError 应该恒为 GL_NO_ERROR；一旦有错误，
    // 通常意味着 shader program 未就绪或纹理绑定失效。
    {
        GLenum err = glGetError();
        if (err != GL_NO_ERROR)
        {
            static int errCount = 0;
            if (errCount++ < 20)
            {
                L2DLOG("GL error 0x%x viewSize=%dx%d loaded=%d",
                       err, view->width, view->height,
                       (view->model && view->model->IsLoaded()) ? 1 : 0);
            }
        }
    }

    if (view->model && view->model->IsLoaded())
    {
        view->model->Update();
        // Update() 之后内容边界才是最新的 -> 每帧重新适配一次
        // （模型矩阵的缩放/居中依赖它，motion 摆动时边界也会变）
        ApplyViewportFit(view);
        CubismMatrix44 mvp = view->projection;
        // 贴边紧凑模式：把模型在视图内缩小并靠到右上角
        // （TextureView 不能做 transform，只能改渲染矩阵）
        // 贴边紧凑模式：把 canvas 缩到窄条大小（renderScale < 1），
        // 并把**角色本体**（不是 canvas）对齐到中心。
        // Live2D 的 canvas 四周有留白，角色本体不在 canvas 中心，
        // 不校正的话缩放后角色偏出去（贴边时只露出腿）。
        {
            // 贴边紧凑模式的缩放**在模型矩阵里做**（见 ApplyViewportFit），
            // 这里不再缩放投影矩阵 —— 投影缩放会和 SetCenterPosition 的
            // 居中补偿互相打架（模型跑到角落、只露出一部分）。
        }
        view->model->Draw(mvp);
    }
}

// ---------------------------------------------------------------------------
// JNI: model
// ---------------------------------------------------------------------------

JNIEXPORT jboolean JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeLoadModel(JNIEnv* env, jclass,
    jlong handle, jstring modelDir, jstring modelFileName)
{
    Live2DView* view = AsView(handle);
    if (!view) return JNI_FALSE;

    const char* dir  = env->GetStringUTFChars(modelDir,      nullptr);
    const char* file = env->GetStringUTFChars(modelFileName, nullptr);

    bool ok = false;
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
    }

    env->ReleaseStringUTFChars(modelDir,      dir);
    env->ReleaseStringUTFChars(modelFileName, file);

    return (ok && view->model && view->model->IsLoaded()) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeUnloadModel(JNIEnv*, jclass, jlong handle)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    delete view->model;
    view->model = nullptr;
    if (view->textureManager) view->textureManager->ReleaseTextures();
}

// ---------------------------------------------------------------------------
// JNI: touch events
// ---------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnTouchBegan(JNIEnv*, jclass, jlong handle,
    jfloat x, jfloat y)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model || view->width <= 0 || view->height <= 0) return;
    view->model->SetDragging(
        (2.0f * x / view->width  - 1.0f),
        -(2.0f * y / view->height - 1.0f));
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnTouchMoved(JNIEnv*, jclass, jlong handle,
    jfloat x, jfloat y)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model || view->width <= 0 || view->height <= 0) return;
    view->model->SetDragging(
        (2.0f * x / view->width  - 1.0f),
        -(2.0f * y / view->height - 1.0f));
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnTouchEnded(JNIEnv*, jclass, jlong handle,
    jfloat, jfloat)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model) return;
    view->model->SetDragging(0.0f, 0.0f);
}

// ---------------------------------------------------------------------------
// JNI: motion / expression / parameter
// ---------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeStartMotion(JNIEnv* env, jclass, jlong handle,
    jstring group, jint index, jint priority)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model || !view->model->IsLoaded()) return;
    const char* g = env->GetStringUTFChars(group, nullptr);
    view->model->StartMotion(g, index, priority);
    env->ReleaseStringUTFChars(group, g);
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeSetExpression(JNIEnv*, jclass, jlong handle,
    jint index)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model || !view->model->IsLoaded()) return;
    view->model->SetExpression(index);
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeSetParameter(JNIEnv* env, jclass, jlong handle,
    jstring parameterId, jfloat value)
{
    Live2DView* view = AsView(handle);
    if (!view) return;
    const char* id = env->GetStringUTFChars(parameterId, nullptr);
    // 特殊参数要在「模型是否加载」之前处理 —— 边界是先到的，模型后加载
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
    // 模型放大系数（设置里的「模型大小」）：原生适配后角色常比 WebView 略小，
    // 允许用户手动放大（这个滑杆以前只对 WebView 生效）。
    if (std::string(id) == "__zoom__")
    {
        view->renderZoom = (value >= 0.2f && value <= 4.0f) ? value : 1.0f;
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    if (!view->model || !view->model->IsLoaded())
    {
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    // 贴边紧凑模式的三个特殊参数：开关和尺寸可能在模型就绪前就下发
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
    if (std::string(id) == "__render_scale__")
    {
        view->renderScale = (value > 0.05f && value <= 1.0f) ? value : 1.0f;
        __android_log_print(ANDROID_LOG_INFO, "Live2DPlugin",
                            "setParameter __render_scale__ = %.3f", (double)value);
        env->ReleaseStringUTFChars(parameterId, id);
        return;
    }
    // 用 SetExternalParameter：每帧 Update() 开头会 LoadParameters() 重置参数，
    // 直接 SetParameterValue 的值活不过一帧（嘴型永远是 0）
    view->model->SetExternalParameter(id, value);
    env->ReleaseStringUTFChars(parameterId, id);
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeSetMotionSpeed(JNIEnv*, jclass, jlong handle,
    jfloat speed)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model) return;
    view->model->SetMotionSpeed(speed);
}

} // extern "C"