#include "flutter_live2d_windows_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <functional>
#include <variant>

namespace flutter_live2d_windows {

namespace {
constexpr char kChannelName[] = "flutter_live2d_windows";

bool GetStringArg(const flutter::EncodableMap* args, const char* key,
                  std::string* out) {
  if (!args) return false;
  auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return false;
  if (const auto* v = std::get_if<std::string>(&it->second)) {
    *out = *v;
    return true;
  }
  return false;
}

int64_t GetIntArg(const flutter::EncodableMap* args, const char* key,
                  int64_t fallback) {
  if (!args) return fallback;
  auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return fallback;
  if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<int64_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<double>(&it->second)) return static_cast<int64_t>(*v);
  return fallback;
}


// 从 EncodableMap 取 double（Dart 侧统一传 double，避免 int32/int64 分叉）
bool GetDoubleArg(const flutter::EncodableMap* args, const char* key, double* out) {
  if (!args) return false;
  auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return false;
  if (const auto* v = std::get_if<double>(&it->second)) {
    *out = *v;
    return true;
  }
  if (const auto* i = std::get_if<int32_t>(&it->second)) {
    *out = static_cast<double>(*i);
    return true;
  }
  if (const auto* l = std::get_if<int64_t>(&it->second)) {
    *out = static_cast<double>(*l);
    return true;
  }
  return false;
}
}  // namespace

void FlutterLive2dWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterLive2dWindowsPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_raw = plugin.get()](
          const flutter::MethodCall<flutter::EncodableValue>& method_call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        plugin_raw->HandleMethodCall(method_call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

FlutterLive2dWindowsPlugin::FlutterLive2dWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

FlutterLive2dWindowsPlugin::~FlutterLive2dWindowsPlugin() {
  DestroyTexture();
  if (renderer_) {
    renderer_->Stop();
    renderer_.reset();
  }
}

int64_t FlutterLive2dWindowsPlugin::CreateTexture() {
  if (texture_id_ >= 0) return texture_id_;
  pixel_texture_ = std::make_unique<flutter::PixelBufferTexture>(
      [this](size_t width, size_t height) -> const FlutterDesktopPixelBuffer* {
        return CopyFrame(width, height);
      });
  texture_variant_ =
      std::make_unique<flutter::TextureVariant>(*pixel_texture_);
  texture_id_ = registrar_->texture_registrar()->RegisterTexture(
      texture_variant_.get());
  return texture_id_;
}

void FlutterLive2dWindowsPlugin::DestroyTexture() {
  if (texture_id_ < 0) {
    texture_variant_.reset();
    pixel_texture_.reset();
    return;
  }

  const int64_t id = texture_id_;
  texture_id_ = -1;

  // ⚠️ 关键：不能 UnregisterTexture(id, nullptr) 之后立刻释放 variant。
  // 引擎在那之后可能还在用这块纹理（下一帧合成），立刻 reset 就是
  // use-after-free —— 表现就是「来回切换几次后 create 报 PlatformException」。
  // 把所有权交给 unregister 的回调，等引擎确认不再使用再释放。
  //
  // 用 shared_ptr 而不是 unique_ptr：回调是 std::function，要求可拷贝。
  auto variant = std::shared_ptr<flutter::TextureVariant>(std::move(texture_variant_));
  auto pixel = std::shared_ptr<flutter::PixelBufferTexture>(std::move(pixel_texture_));
  registrar_->texture_registrar()->UnregisterTexture(
      id, [variant, pixel]() {
        // 捕获即持有；回调返回后引用计数归零，纹理对象在这里才真正释放
      });
}

const FlutterDesktopPixelBuffer*
FlutterLive2dWindowsPlugin::CopyFrame(size_t width, size_t height) {
  int w = 0, h = 0;
  const uint8_t* pixels = renderer_ ? renderer_->AcquirePublished(&w, &h) : nullptr;
  if (!pixels) return nullptr;
  pixel_buffer_.buffer = pixels;
  pixel_buffer_.width = static_cast<size_t>(w);
  pixel_buffer_.height = static_cast<size_t>(h);
  pixel_buffer_.release_callback = nullptr;  // 帧数据由 renderer 双缓冲持有
  return &pixel_buffer_;
}

void FlutterLive2dWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = method_call.method_name();
  const auto* args =
      std::get_if<flutter::EncodableMap>(method_call.arguments());

  if (method == "create") {
    double w = 0, h = 0;
    if (!GetDoubleArg(args, "width", &w) || !GetDoubleArg(args, "height", &h) ||
        w < 1 || h < 1) {
      result->Error("bad_args", "create 需要正数 width/height");
      return;
    }
    // 不复用旧实例：Start 失败后残留的渲染线程会「看起来存在但没跑」，
    // 下次 create 走复用分支就永远起不来（表现为来回切换几次后一直失败）。
    if (renderer_) {
      renderer_->SetOnFrameAvailable(nullptr);
      renderer_->Stop();
      renderer_.reset();
    }
    renderer_ = std::make_unique<Live2DRenderThread>();

    const int64_t id = CreateTexture();
    if (id < 0) {
      renderer_.reset();
      result->Error("texture", "纹理注册失败");
      return;
    }
    // 每帧产出后通知引擎取新帧（渲染线程调用）。
    // 纹理可能已被 dispose 注销（texture_id_ = -1），必须判断，否则
    // MarkTextureFrameAvailable(-1) 会打到无效的纹理 id 上。
    renderer_->SetOnFrameAvailable([this] {
      if (texture_id_ >= 0) {
        registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
      }
    });
    if (!renderer_->Start(static_cast<int>(w), static_cast<int>(h))) {
      // 回滚：停掉线程 + 注销刚注册的纹理，否则下次 create 拿到「半成品」状态
      renderer_->SetOnFrameAvailable(nullptr);
      renderer_->Stop();
      renderer_.reset();
      DestroyTexture();
      result->Error("renderer", "渲染线程启动失败");
      return;
    }
    // Start 只是起线程，GL 上下文是在线程里建的 —— 必须等就绪确认，
    // 否则失败时上层拿到「create 成功但永远空白」，无从排查。
    if (!renderer_->WaitReady(3000)) {
      renderer_->SetOnFrameAvailable(nullptr);
      renderer_->Stop();
      renderer_.reset();
      DestroyTexture();
      result->Error("gl_context",
                    "GL 上下文创建失败（显卡驱动不支持 OpenGL 3.3 "
                    "或上下文数量过多，重启应用可释放）");
      return;
    }
    result->Success(flutter::EncodableValue(id));
    return;
  }

  if (method == "setSize") {
    double w = 0, h = 0;
    if (GetDoubleArg(args, "width", &w) && GetDoubleArg(args, "height", &h) &&
        renderer_) {
      renderer_->Resize(static_cast<int>(w), static_cast<int>(h));
    }
    result->Success();
    return;
  }

  if (method == "setPaused") {
    if (renderer_ && args) {
      auto it = args->find(flutter::EncodableValue("paused"));
      if (it != args->end()) {
        if (const auto* v = std::get_if<bool>(&it->second)) {
          renderer_->SetPaused(*v);
        }
      }
    }
    result->Success();
    return;
  }

  if (method == "dispose") {
    if (renderer_) {
      renderer_->SetOnFrameAvailable(nullptr);
      renderer_->Stop();
      renderer_.reset();
    }
    DestroyTexture();
    result->Success();
    return;
  }

  if (method == "loadModel") {
    std::string dir, file;
    if (!renderer_) {
      result->Error("renderer", "需先 create");
      return;
    }
    if (!GetStringArg(args, "dir", &dir) || !GetStringArg(args, "file", &file)) {
      result->Error("bad_args", "loadModel 需要字符串 dir/file");
      return;
    }
    result->Success(flutter::EncodableValue(renderer_->LoadModel(dir, file)));
    return;
  }

  if (method == "setZoom") {
    double zoom = 1.0;
    if (renderer_ && GetDoubleArg(args, "zoom", &zoom)) {
      renderer_->SetZoom(static_cast<float>(zoom));
    }
    result->Success();
    return;
  }

  if (method == "setFitBounds") {
    double cx = 0, cy = 0, w = 0, h = 0;
    if (renderer_ && GetDoubleArg(args, "cx", &cx) &&
        GetDoubleArg(args, "cy", &cy) && GetDoubleArg(args, "w", &w) &&
        GetDoubleArg(args, "h", &h)) {
      renderer_->SetFitBounds(static_cast<float>(cx), static_cast<float>(cy),
                              static_cast<float>(w), static_cast<float>(h));
    }
    result->Success();
    return;
  }

  if (method == "setParameter") {
    std::string id;
    if (renderer_ && GetStringArg(args, "id", &id)) {
      double v = 0;
      if (GetDoubleArg(args, "value", &v)) {
        renderer_->SetParameter(id, static_cast<float>(v));
      }
    }
    result->Success();
    return;
  }

  if (method == "startMotion") {
    std::string group;
    if (renderer_ && GetStringArg(args, "group", &group)) {
      const int index = static_cast<int>(GetIntArg(args, "index", 0));
      const int priority = static_cast<int>(GetIntArg(args, "priority", 1));
      renderer_->StartMotion(group, index, priority);
    }
    result->Success();
    return;
  }

  // 尚未实现的能力
  result->NotImplemented();
}

}  // namespace flutter_live2d_windows
