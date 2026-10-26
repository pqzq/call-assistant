#ifndef FLUTTER_PLUGIN_FLUTTER_LIVE2D_WINDOWS_RENDER_THREAD_H_
#define FLUTTER_PLUGIN_FLUTTER_LIVE2D_WINDOWS_RENDER_THREAD_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <vector>

// 真实类在全局命名空间（live2d/ 下），这里只能前向声明同名全局类
class Live2DTextureManager;
class Live2DModel;

namespace flutter_live2d_windows {

// 独立渲染线程：隐藏窗口 + WGL 上下文，每帧渲染到 FBO/后台缓冲并 glReadPixels
// 回读为 RGBA8，双缓冲发布给纹理拷贝回调（光栅线程读取）。
class Live2DRenderThread {
 public:
  Live2DRenderThread() = default;
  ~Live2DRenderThread();

  Live2DRenderThread(const Live2DRenderThread&) = delete;
  Live2DRenderThread& operator=(const Live2DRenderThread&) = delete;

  // 每帧产出后回调（用于 MarkTextureFrameAvailable），在渲染线程调用
  void SetOnFrameAvailable(std::function<void()> cb) { on_frame_ = std::move(cb); }

  bool Start(int width, int height);

  /// 等待渲染线程真正就绪（GL 上下文创建完成）。
  ///
  /// `Start()` 只是起线程，窗口/GL 上下文是在线程里创建的，失败时线程会
  /// 静默退出（只把 running_ 置 false）。上层必须等这个确认，否则
  /// 「create 成功返回、画面却永远空白」，排查时毫无线索。
  bool WaitReady(int timeout_ms);

  void Stop();
  void Resize(int width, int height);

  /// 模型放大系数（1.0 = 按自动适配结果显示）
  void SetZoom(float zoom);

  /// 设置「角色本体」在 canvas 里的归一化矩形（中心x, 中心y, 宽, 高）
  ///
  /// 传 0 宽高表示清空（退回按 canvas 适配）。
  /// 原生侧没有 getLocalBounds() 的等价 API：用 canvas 会偏小，
  /// 用 drawable 顶点外框会更小（外框含背景/遮罩），所以由 WebView 侧量好传进来。
  void SetFitBounds(float cx, float cy, float w, float h);
  int width() const { return width_.load(); }
  int height() const { return height_.load(); }

  // 纹理拷贝回调（光栅线程）取当前已发布帧；无帧时返回 nullptr
  /// 把最新一帧**拷贝**到 out（持 size_mutex_，与 resize 互斥）
  ///
  /// ⚠️ 不能返回指向内部缓冲的指针：窗口 resize 时渲染线程会
  /// `buffers_[i].resize()` 重新分配，光栅线程手里那个指针立刻失效 ——
  /// 引擎再去读就是 use-after-free，表现为「窗口放大就卡死闪退」。
  bool CopyPublished(std::vector<uint8_t>* out, int* w, int* h);

  // —— M1：模型渲染（平台线程调用，命令入队后在渲染线程执行）——
  bool LoadModel(const std::string& dir, const std::string& file);
  void SetParameter(const std::string& id, float value);
  void StartMotion(const std::string& group, int index, int priority);
  bool model_loaded() const { return model_loaded_.load(); }

  /// 暂停/恢复出帧（窗口最小化/不可见时省 CPU，上下文保留）
  void SetPaused(bool paused) { paused_ = paused; }

 private:
  void RenderLoop();
  bool CreateWindowAndContext();
  bool UpgradeContext();  // 临时 GL1.1 上下文升级到 3.3 compat（Cubism 需 GLSL120+）
  void DestroyWindowAndContext();
  void RenderFrame(double t_seconds);
  void PublishFrame();  // 把 write 缓冲交换为 published 并清空 write

  void DrainCommands();
  void DoLoadModel(const std::string& dir, const std::string& file);  // 渲染线程
  void EnsureFbo(int w, int h);
  bool RenderModel(int w, int h);  // 画模型到 FBO；无模型返回 false

  // Cubism 对象/GL 资源（仅渲染线程访问；前向声明指针避免头文件依赖 GL）
  ::Live2DTextureManager* textureManager_ = nullptr;
  ::Live2DModel* model_ = nullptr;
  unsigned fbo_ = 0;
  unsigned colorTex_ = 0;
  int fboW_ = 0;
  int fboH_ = 0;

  std::function<void()> on_frame_;
  std::thread thread_;
  std::atomic<bool> running_{false};
  /// 渲染线程已建好 GL 上下文（RenderLoop 成功后才置 true）
  std::atomic<bool> ready_{false};

  /// 模型放大系数（平台线程写、渲染线程读）
  std::atomic<float> zoom_{1.0f};

  /// 角色本体在 canvas 里的归一化矩形（中心x, 中心y, 宽, 高）
  std::atomic<float> fitCx_{0.0f};
  std::atomic<float> fitCy_{0.0f};
  std::atomic<float> fitW_{0.0f};
  std::atomic<float> fitH_{0.0f};
  std::atomic<bool> fitValid_{false};

  HWND window_ = nullptr;
  HDC dc_ = nullptr;
  HGLRC gl_context_ = nullptr;

  std::atomic<int> width_{1};
  std::atomic<int> height_{1};
  std::mutex size_mutex_;
  bool size_dirty_ = false;

  // 双缓冲：write_ 由渲染线程写，published_ 供光栅线程读；交换用原子索引
  std::vector<uint8_t> buffers_[2];
  std::atomic<int> write_idx_{0};               // 渲染线程正在写
  std::atomic<int> published_idx_{-1};          // 光栅线程可读（-1=无帧）

  std::mutex cmd_mutex_;
  std::queue<std::function<void()>> cmds_;
  std::atomic<bool> model_loaded_{false};
  std::atomic<bool> paused_{false};
};

}  // namespace flutter_live2d_windows

#endif  // FLUTTER_PLUGIN_FLUTTER_LIVE2D_WINDOWS_RENDER_THREAD_H_
