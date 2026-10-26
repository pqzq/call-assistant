#ifndef FLUTTER_PLUGIN_FLUTTER_LIVE2D_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_LIVE2D_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <map>
#include <memory>
#include <vector>

#include "renderer/live2d_render_thread.h"

namespace flutter_live2d_windows {

class FlutterLive2dWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit FlutterLive2dWindowsPlugin(flutter::PluginRegistrarWindows* registrar);

  ~FlutterLive2dWindowsPlugin() override;

  // Disallow copy and assign.
  FlutterLive2dWindowsPlugin(const FlutterLive2dWindowsPlugin&) = delete;
  FlutterLive2dWindowsPlugin& operator=(const FlutterLive2dWindowsPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  /// 一个渲染实例（对应 Dart 侧一个 WindowsLive2DController）
  ///
  /// ⚠️ **必须支持多实例**：桌面分栏和全屏演示页的数字人可能同时存在，
  /// 切换页面时还会短暂重叠。以前这里是单个全局实例 —— 任何一个
  /// controller 的 dispose 都会把它销毁（并注销纹理），
  /// 表现为「打开演示模式后两边都空白」。
  struct Instance {
    std::unique_ptr<Live2DRenderThread> renderer;
    std::unique_ptr<flutter::PixelBufferTexture> pixel_texture;
    std::unique_ptr<flutter::TextureVariant> texture_variant;
    int64_t texture_id = -1;
    // 回调返回值的宿主（引擎在回调返回前同步拷走像素）
    FlutterDesktopPixelBuffer pixel_buffer = {};
    // 帧数据暂存：渲染线程的缓冲会在 resize 时重新分配，
    // 不能把它的指针直接交给引擎（会 use-after-free → 窗口放大闪退）
    std::vector<uint8_t> scratch;
  };

  /// 纹理拷贝回调（光栅线程同步调用）：指向已发布帧；无帧返回 nullptr
  const FlutterDesktopPixelBuffer* CopyFrame(Instance* inst, size_t width,
                                             size_t height);

  int64_t CreateTexture(Instance* inst);
  void DestroyTexture(Instance* inst);

  /// 按 id 找实例；找不到返回 nullptr
  Instance* Find(int64_t id);

  flutter::PluginRegistrarWindows* registrar_;
  int64_t next_instance_id_ = 1;
  std::map<int64_t, std::unique_ptr<Instance>> instances_;
};

}  // namespace flutter_live2d_windows

#endif  // FLUTTER_PLUGIN_FLUTTER_LIVE2D_WINDOWS_PLUGIN_H_
