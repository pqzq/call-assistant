#ifndef FLUTTER_PLUGIN_FLUTTER_LIVE2D_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_LIVE2D_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <memory>

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
  // 纹理拷贝回调（光栅线程同步调用）：指向已发布帧；无帧返回 nullptr
  const FlutterDesktopPixelBuffer* CopyFrame(size_t width, size_t height);

  int64_t CreateTexture();
  void DestroyTexture();

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<Live2DRenderThread> renderer_;
  std::unique_ptr<flutter::PixelBufferTexture> pixel_texture_;
  std::unique_ptr<flutter::TextureVariant> texture_variant_;
  int64_t texture_id_ = -1;
  // 回调返回值的宿主（引擎在回调返回前同步拷走像素）
  FlutterDesktopPixelBuffer pixel_buffer_ = {};
};

}  // namespace flutter_live2d_windows

#endif  // FLUTTER_PLUGIN_FLUTTER_LIVE2D_WINDOWS_PLUGIN_H_
