#include "live2d_render_thread.h"

#include <GL/glew.h>
#include <GL/wglew.h>

#include "../live2d/Live2DAllocator.hpp"
#include "../live2d/Live2DModel.hpp"
#include "../live2d/Live2DPal.hpp"
#include "../live2d/Live2DTextureManager.hpp"
#include "../live2d/live2d_log.h"

#include <CubismFramework.hpp>
#include <Math/CubismMatrix44.hpp>
#include <Rendering/OpenGL/CubismRenderer_OpenGLES2.hpp>

#include <chrono>
#include <cmath>

// 新版 Windows SDK 已删除 wingd.h、GL/gl.h 也不再声明 wgl*，手动补上
// （均由 opengl32.lib 导出）。
extern "C" {
__declspec(dllimport) HGLRC WINAPI wglCreateContext(HDC hDC);
__declspec(dllimport) BOOL WINAPI wglMakeCurrent(HDC hDC, HGLRC hGLRC);
__declspec(dllimport) BOOL WINAPI wglDeleteContext(HGLRC hGLRC);
}

namespace flutter_live2d_windows {

namespace Csm = Live2D::Cubism::Framework;

namespace {

constexpr wchar_t kWindowClassName[] = L"FlutterLive2dWindowsOffscreen";

ATOM RegisterWindowClassOnce() {
  static ATOM atom = [] {
    WNDCLASS wc = {};
    wc.lpfnWndProc = ::DefWindowProc;
    wc.hInstance = ::GetModuleHandle(nullptr);
    wc.lpszClassName = kWindowClassName;
    return ::RegisterClass(&wc);
  }();
  return atom;
}

// —— Cubism Framework 生命周期（进程级，多渲染线程共享引用计数）——
Live2DAllocator g_allocator;
Csm::CubismFramework::Option g_option;
int g_frameworkRef = 0;

void CubismLog(const char* message) {
  if (message) L2DLOG("[cubism] %s", message);
}

void FrameworkRetain() {
  if (g_frameworkRef++ != 0) return;
  g_option.LogFunction = CubismLog;
  g_option.LoggingLevel = Csm::CubismFramework::Option::LogLevel_Verbose;
  g_option.LoadFileFunction = Live2DPal::LoadFileAsBytes;
  g_option.ReleaseBytesFunction = Live2DPal::ReleaseBytes;
  Csm::CubismFramework::StartUp(&g_allocator, &g_option);
  Csm::CubismFramework::Initialize();
}

void FrameworkRelease() {
  if (--g_frameworkRef <= 0) {
    g_frameworkRef = 0;
    Csm::CubismFramework::Dispose();
  }
}

void ConfigureRendererForStability(Live2DModel* model) {
  if (!model) return;
  auto* renderer =
      model->GetRenderer<Csm::Rendering::CubismRenderer_OpenGLES2>();
  if (renderer) renderer->UseHighPrecisionMask(false);
}

// glReadPixels 首行是图像底部；Flutter 像素纹理要求首行是顶部 → 原地翻转
void FlipRowsInPlace(uint8_t* buf, int w, int h) {
  const size_t row = static_cast<size_t>(w) * 4;
  uint8_t tmp[4096 * 4];
  for (int y = 0; y < h / 2; y++) {
    uint8_t* a = buf + row * y;
    uint8_t* b = buf + row * (h - 1 - y);
    if (row <= sizeof(tmp)) {
      memcpy(tmp, a, row);
      memcpy(a, b, row);
      memcpy(b, tmp, row);
    } else {
      uint8_t* big = new uint8_t[row];
      memcpy(big, a, row);
      memcpy(a, b, row);
      memcpy(b, big, row);
      delete[] big;
    }
  }
}

}  // namespace

Live2DRenderThread::~Live2DRenderThread() { Stop(); }

bool Live2DRenderThread::Start(int width, int height) {
  if (running_.load()) return false;
  if (width < 1) width = 1;
  if (height < 1) height = 1;
  width_ = width;
  height_ = height;
  // 首帧缓冲必须在循环前分配好（否则循环卡在 empty 永远 continue）
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  buffers_[0].resize(bytes);
  buffers_[1].resize(bytes);
  running_ = true;
  thread_ = std::thread([this] { RenderLoop(); });
  return true;
}

void Live2DRenderThread::Stop() {
  running_ = false;
  if (thread_.joinable()) thread_.join();
}

void Live2DRenderThread::Resize(int width, int height) {
  if (width < 1) width = 1;
  if (height < 1) height = 1;
  std::lock_guard<std::mutex> lock(size_mutex_);
  if (width_.load() == width && height_.load() == height) return;
  width_ = width;
  height_ = height;
  size_dirty_ = true;
}

const uint8_t* Live2DRenderThread::AcquirePublished(int* w, int* h) {
  int idx = published_idx_.load();
  if (idx < 0) return nullptr;
  *w = width_.load();
  *h = height_.load();
  return buffers_[idx].data();
}

// —— 平台线程入口：命令入队，渲染线程执行 ——

bool Live2DRenderThread::LoadModel(const std::string& dir,
                                   const std::string& file) {
  if (!running_.load()) return false;
  std::string dirCopy = dir;
  if (!dirCopy.empty() && dirCopy.back() != '/' && dirCopy.back() != '\\') {
    dirCopy += '/';
  }
  std::string fileCopy = file;
  {
    std::lock_guard<std::mutex> lock(cmd_mutex_);
    cmds_.push([this, dirCopy, fileCopy] { DoLoadModel(dirCopy, fileCopy); });
  }
  return true;
}

void Live2DRenderThread::SetParameter(const std::string& id, float value) {
  if (!running_.load()) return;
  std::string idCopy = id;
  std::lock_guard<std::mutex> lock(cmd_mutex_);
  cmds_.push([this, idCopy, value] {
    if (model_) {
      model_->SetExternalParameter(idCopy.c_str(), value);
    }
  });
}

void Live2DRenderThread::StartMotion(const std::string& group, int index,
                                     int priority) {
  if (!running_.load()) return;
  std::string groupCopy = group;
  std::lock_guard<std::mutex> lock(cmd_mutex_);
  cmds_.push([this, groupCopy, index, priority] {
    if (model_) {
      model_->StartMotion(groupCopy.c_str(), index, priority);
    }
  });
}

void Live2DRenderThread::DrainCommands() {
  for (;;) {
    std::function<void()> cmd;
    {
      std::lock_guard<std::mutex> lock(cmd_mutex_);
      if (cmds_.empty()) return;
      cmd = std::move(cmds_.front());
      cmds_.pop();
    }
    cmd();
  }
}

void Live2DRenderThread::DoLoadModel(const std::string& dir,
                                     const std::string& file) {
  if (!textureManager_) return;
  model_loaded_ = false;
  delete model_;
  model_ = nullptr;
  textureManager_->ReleaseTextures();

  auto* model = new Live2DModel(textureManager_);
  model->LoadAssets(dir.c_str(), file.c_str());
  if (!model->IsLoaded()) {
    L2DLOG("DoLoadModel: load failed %s%s", dir.c_str(), file.c_str());
    delete model;
    return;
  }
  model->CreateRenderer(static_cast<Csm::csmUint32>(width_.load()),
                        static_cast<Csm::csmUint32>(height_.load()));
  ConfigureRendererForStability(model);
  model->SetupTextures();
  model_ = model;
  model_loaded_ = true;
  L2DLOG("DoLoadModel: loaded %s%s", dir.c_str(), file.c_str());
}

bool Live2DRenderThread::CreateWindowAndContext() {
  if (RegisterWindowClassOnce() == 0) return false;

  // 不可见的普通弹出窗口：有真实 DC/后台缓冲，但不上屏
  window_ = ::CreateWindowEx(0, kWindowClassName, L"", WS_POPUP, 0, 0, 2, 2,
                             nullptr, nullptr, GetModuleHandle(nullptr),
                             nullptr);
  if (!window_) return false;

  dc_ = ::GetDC(window_);
  if (!dc_) return false;

  PIXELFORMATDESCRIPTOR pfd = {};
  pfd.nSize = sizeof(pfd);
  pfd.nVersion = 1;
  pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
  pfd.iPixelType = PFD_TYPE_RGBA;
  pfd.cColorBits = 32;
  pfd.cAlphaBits = 8;
  pfd.cDepthBits = 24;
  pfd.cStencilBits = 8;  // Cubism 遮罩需要 stencil
  pfd.iLayerType = PFD_MAIN_PLANE;

  const int format = ::ChoosePixelFormat(dc_, &pfd);
  if (format == 0) return false;
  if (!::SetPixelFormat(dc_, format, &pfd)) return false;

  gl_context_ = ::wglCreateContext(dc_);
  if (!gl_context_) return false;
  if (!::wglMakeCurrent(dc_, gl_context_)) return false;
  return true;
}

void Live2DRenderThread::DestroyWindowAndContext() {
  if (gl_context_) {
    ::wglMakeCurrent(nullptr, nullptr);
    ::wglDeleteContext(gl_context_);
    gl_context_ = nullptr;
  }
  if (dc_ && window_) ::ReleaseDC(window_, dc_);
  dc_ = nullptr;
  if (window_) {
    ::DestroyWindow(window_);
    window_ = nullptr;
  }
}

// 把临时 GL 1.1 上下文升级到 3.3 compatibility（Cubism 桌面 shader 是 GLSL 120，
// opengl32.dll 原生上下文只有 1.1，必须走 wglCreateContextAttribsARB）。
bool Live2DRenderThread::UpgradeContext() {
  if (!WGLEW_ARB_create_context || !WGLEW_ARB_pixel_format) return false;

  const int pixAttribs[] = {
      WGL_SUPPORT_OPENGL_ARB, TRUE,
      WGL_DRAW_TO_WINDOW_ARB, TRUE,
      WGL_DOUBLE_BUFFER_ARB, TRUE,
      WGL_COLOR_BITS_ARB, 32,
      WGL_ALPHA_BITS_ARB, 8,
      WGL_DEPTH_BITS_ARB, 24,
      WGL_STENCIL_BITS_ARB, 8,
      0};
  int fmt = 0;
  UINT got = 0;
  if (!wglChoosePixelFormatARB(dc_, pixAttribs, nullptr, 1, &fmt, &got) ||
      got == 0 || fmt == 0) {
    return false;
  }
  PIXELFORMATDESCRIPTOR actual = {};
  if (DescribePixelFormat(dc_, fmt, sizeof(actual), &actual) == 0) return false;
  if (!SetPixelFormat(dc_, fmt, &actual)) return false;

  const int ctxAttribs[] = {
      WGL_CONTEXT_MAJOR_VERSION_ARB, 3,
      WGL_CONTEXT_MINOR_VERSION_ARB, 3,
      WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB,
      0};
  HGLRC upgraded = wglCreateContextAttribsARB(dc_, nullptr, ctxAttribs);
  if (!upgraded) return false;

  wglMakeCurrent(nullptr, nullptr);
  wglDeleteContext(gl_context_);
  gl_context_ = upgraded;
  return wglMakeCurrent(dc_, gl_context_) != FALSE;
}

void Live2DRenderThread::RenderLoop() {
  if (!CreateWindowAndContext()) {
    running_ = false;
    DestroyWindowAndContext();
    return;
  }

  setvbuf(stdout, nullptr, _IONBF, 0);  // 重定向时日志不被缓冲吃掉

  if (glewInit() != GLEW_OK) {
    L2DLOG("glewInit failed");
    running_ = false;
    DestroyWindowAndContext();
    return;
  }
  glGetError();  // glewInit 会留下一个虚假错误，清掉

  if (UpgradeContext()) {
    glewInit();  // 新上下文重建分发表
    glGetError();
    L2DLOG("GL context upgraded: %s", (const char*)glGetString(GL_VERSION));
  } else {
    L2DLOG("GL context upgrade FAILED, stuck on %s", (const char*)glGetString(GL_VERSION));
  }

  FrameworkRetain();
  textureManager_ = new Live2DTextureManager();

  const LARGE_INTEGER freq = [] {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    return f;
  }();
  LARGE_INTEGER start;
  QueryPerformanceCounter(&start);

  while (running_.load()) {
    MSG msg;
    while (::PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }

    // 先排命令（loadModel 等不依赖回读缓冲）
    DrainCommands();

    // 暂停（窗口不可见）：不出帧不烧 CPU，但保持上下文与命令响应
    if (paused_.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      continue;
    }

    {
      std::lock_guard<std::mutex> lock(size_mutex_);
      if (size_dirty_) {
        const size_t bytes =
            static_cast<size_t>(width_.load()) * height_.load() * 4;
        buffers_[0].resize(bytes);
        buffers_[1].resize(bytes);
        published_idx_ = -1;
        size_dirty_ = false;
      }
    }
    if (buffers_[0].empty()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(33));
      continue;
    }

    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    const double t = double(now.QuadPart - start.QuadPart) / double(freq.QuadPart);

    const int w = width_.load(), h = height_.load();
    bool drewModel = false;
    if (model_loaded_.load()) {
      drewModel = RenderModel(w, h);
    }
    if (!drewModel) {
      RenderFrame(t);
    }
    PublishFrame();
    if (on_frame_) on_frame_();

    std::this_thread::sleep_for(std::chrono::milliseconds(33));  // ~30fps：readback 管线成本减半
  }

  // 释放（都在渲染线程、GL 上下文还活着时做）
  delete model_;
  model_ = nullptr;
  if (textureManager_) {
    textureManager_->ReleaseTextures();
    delete textureManager_;
    textureManager_ = nullptr;
  }
  if (fbo_) glDeleteFramebuffers(1, &fbo_);
  if (colorTex_) glDeleteTextures(1, &colorTex_);
  FrameworkRelease();
  DestroyWindowAndContext();
}

// M0 兜底路径：渲染到默认后台缓冲的动画清屏色（无模型时可见管线在工作）
void Live2DRenderThread::RenderFrame(double t_seconds) {
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(0, 0, width_.load(), height_.load());
  const float r = 0.5f + 0.45f * static_cast<float>(std::sin(t_seconds * 1.3));
  const float g = 0.5f + 0.45f * static_cast<float>(std::sin(t_seconds * 1.7 + 2.0));
  const float b = 0.5f + 0.45f * static_cast<float>(std::sin(t_seconds * 2.1 + 4.0));
  glClearColor(r, g, b, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  glFinish();

  const int w = width_.load(), h = height_.load();
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE,
               buffers_[write_idx_.load()].data());
  FlipRowsInPlace(buffers_[write_idx_.load()].data(), w, h);
}

void Live2DRenderThread::EnsureFbo(int w, int h) {
  if (fbo_ && fboW_ == w && fboH_ == h) return;
  if (fbo_) {
    glDeleteFramebuffers(1, &fbo_);
    fbo_ = 0;
  }
  if (colorTex_) {
    glDeleteTextures(1, &colorTex_);
    colorTex_ = 0;
  }
  glGenTextures(1, &colorTex_);
  glBindTexture(GL_TEXTURE_2D, colorTex_);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE,
               nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glGenFramebuffers(1, &fbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         colorTex_, 0);
  const bool complete =
      glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  fboW_ = complete ? w : 0;
  fboH_ = complete ? h : 0;
  if (!complete) {
    L2DLOG("EnsureFbo: framebuffer incomplete");
    return;
  }
  if (model_) model_->ResizeMaskBuffer(w, h);
}

bool Live2DRenderThread::RenderModel(int w, int h) {
  auto* model = model_;
  if (!model) return false;

  Live2DPal::UpdateTime();
  model->Update();

  // —— 视口适配：整视口居中 contain（与 Android 最终版一致，margin 0.92）——
  float cw = 0.0f, ch = 0.0f;
  model->GetCanvasSize(cw, ch);
  float bminX = 0.0f, bminY = 0.0f, bmaxX = 0.0f, bmaxY = 0.0f;
  model->GetContentBounds(bminX, bminY, bmaxX, bmaxY);
  float fw = bmaxX - bminX;
  float fh = bmaxY - bminY;
  float fcx = (bminX + bmaxX) * 0.5f;
  float fcy = (bminY + bmaxY) * 0.5f;
  if (fw <= 0.0f || fh <= 0.0f) {
    if (cw <= 0.0f || ch <= 0.0f) return false;
    fw = cw;
    fh = ch;
    fcx = 0.0f;
    fcy = 0.0f;
  }
  float px = 1.0f, py = 1.0f;
  Csm::CubismMatrix44 projection;
  projection.LoadIdentity();
  if (w > h) {
    py = static_cast<float>(w) / static_cast<float>(h);
    projection.Scale(1.0f, py);
  } else {
    px = static_cast<float>(h) / static_cast<float>(w);
    projection.Scale(px, 1.0f);
  }
  const float s = fminf(2.0f / (px * fw), 2.0f / (py * fh)) * 0.92f;
  auto* mm = model->GetModelMatrix();
  mm->LoadIdentity();
  mm->ScaleRelative(s, s);
  mm->TranslateRelative(-s * fcx, -s * fcy);

  EnsureFbo(w, h);
  if (!fbo_) return false;

  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glViewport(0, 0, w, h);
  glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  model->Draw(projection);

  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
  glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE,
               buffers_[write_idx_.load()].data());
  FlipRowsInPlace(buffers_[write_idx_.load()].data(), w, h);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  return true;
}

void Live2DRenderThread::PublishFrame() {
  const int w = write_idx_.load();
  published_idx_ = w;  // 该缓冲整帧写完，发布给光栅线程
  write_idx_ = 1 - w;  // 下一帧写另一个缓冲
}

}  // namespace flutter_live2d_windows
