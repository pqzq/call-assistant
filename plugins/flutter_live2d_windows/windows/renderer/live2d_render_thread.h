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
  void Stop();
  void Resize(int width, int height);
  int width() const { return width_.load(); }
  int height() const { return height_.load(); }

  // 纹理拷贝回调（光栅线程）取当前已发布帧；无帧时返回 nullptr
  const uint8_t* AcquirePublished(int* w, int* h);

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
