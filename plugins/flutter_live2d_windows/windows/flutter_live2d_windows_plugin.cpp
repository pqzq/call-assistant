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
  // 逐个释放：每个实例有自己的渲染线程和纹理
  for (auto& entry : instances_) {
    Instance* inst = entry.second.get();
    if (!inst) continue;
    if (inst->renderer) {
      inst->renderer->SetOnFrameAvailable(nullptr);
      inst->renderer->Stop();
      inst->renderer.reset();
    }
    DestroyTexture(inst);
  }
  instances_.clear();
}

FlutterLive2dWindowsPlugin::Instance* FlutterLive2dWindowsPlugin::Find(
    int64_t id) {
  auto it = instances_.find(id);
  return it == instances_.end() ? nullptr : it->second.get();
}

int64_t FlutterLive2dWindowsPlugin::CreateTexture(Instance* inst) {
  if (!inst) return -1;
  if (inst->texture_id >= 0) return inst->texture_id;
  inst->pixel_texture = std::make_unique<flutter::PixelBufferTexture>(
      [this, inst](size_t width,
                   size_t height) -> const FlutterDesktopPixelBuffer* {
        return CopyFrame(inst, width, height);
      });
  inst->texture_variant =
      std::make_unique<flutter::TextureVariant>(*inst->pixel_texture);
  inst->texture_id = registrar_->texture_registrar()->RegisterTexture(
      inst->texture_variant.get());
  return inst->texture_id;
}

void FlutterLive2dWindowsPlugin::DestroyTexture(Instance* inst) {
  if (!inst) return;
  if (inst->texture_id < 0) {
    inst->texture_variant.reset();
    inst->pixel_texture.reset();
    return;
  }

  const int64_t id = inst->texture_id;
  inst->texture_id = -1;

  // ⚠️ 关键：不能 UnregisterTexture(id, nullptr) 之后立刻释放 variant。
  // 引擎在那之后可能还在用这块纹理（下一帧合成），立刻 reset 就是
  // use-after-free —— 表现就是「来回切换几次后 create 报 PlatformException」。
  // 把所有权交给 unregister 的回调，等引擎确认不再使用再释放。
  //
  // 用 shared_ptr 而不是 unique_ptr：回调是 std::function，要求可拷贝。
  auto variant =
      std::shared_ptr<flutter::TextureVariant>(std::move(inst->texture_variant));
  auto pixel =
      std::shared_ptr<flutter::PixelBufferTexture>(std::move(inst->pixel_texture));
  registrar_->texture_registrar()->UnregisterTexture(
      id, [variant, pixel]() {
        // 捕获即持有；回调返回后引用计数归零，纹理对象在这里才真正释放
      });
}

const FlutterDesktopPixelBuffer*
FlutterLive2dWindowsPlugin::CopyFrame(Instance* inst, size_t width,
                                      size_t height) {
  if (!inst || !inst->renderer) return nullptr;
  int w = 0, h = 0;
  // 必须拷到自己这块暂存：渲染线程的缓冲在 resize 时会重新分配，
  // 把它的指针交给引擎就是 use-after-free（窗口放大 → 卡死闪退）。
  if (!inst->renderer->CopyPublished(&inst->scratch, &w, &h)) return nullptr;
  inst->pixel_buffer.buffer = inst->scratch.data();
  inst->pixel_buffer.width = static_cast<size_t>(w);
  inst->pixel_buffer.height = static_cast<size_t>(h);
  inst->pixel_buffer.release_callback = nullptr;  // 数据由 inst->scratch 持有
  return &inst->pixel_buffer;
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

    // 每次 create 都建**独立实例**：分栏和演示页可能同时存在，
    // 共用一个全局实例会互相顶掉（一方 dispose 就把另一方销毁）。
    auto inst = std::make_unique<Instance>();
    inst->renderer = std::make_unique<Live2DRenderThread>();
    Instance* raw = inst.get();

    const int64_t texture_id = CreateTexture(raw);
    if (texture_id < 0) {
      result->Error("texture", "纹理注册失败");
      return;
    }

    // 每帧产出后通知引擎取新帧（渲染线程调用）。
    // 纹理可能已被 dispose 注销，必须判断，否则会打到无效的纹理 id 上。
    raw->renderer->SetOnFrameAvailable([this, raw] {
      if (raw->texture_id >= 0) {
        registrar_->texture_registrar()->MarkTextureFrameAvailable(
            raw->texture_id);
      }
    });

    if (!raw->renderer->Start(static_cast<int>(w), static_cast<int>(h))) {
      raw->renderer->SetOnFrameAvailable(nullptr);
      raw->renderer->Stop();
      raw->renderer.reset();
      DestroyTexture(raw);
      result->Error("renderer", "渲染线程启动失败");
      return;
    }
    // Start 只是起线程，GL 上下文是在线程里建的 —— 必须等就绪确认，
    // 否则失败时上层拿到「create 成功但永远空白」，无从排查。
    if (!raw->renderer->WaitReady(3000)) {
      raw->renderer->SetOnFrameAvailable(nullptr);
      raw->renderer->Stop();
      raw->renderer.reset();
      DestroyTexture(raw);
      result->Error("gl_context",
                    "GL 上下文创建失败（显卡驱动不支持 OpenGL 3.3 "
                    "或上下文数量过多，重启应用可释放）");
      return;
    }

    const int64_t instance_id = next_instance_id_++;
    instances_[instance_id] = std::move(inst);

    // 同时返回实例 id（后续所有调用用它定位）和纹理 id（给 Texture 组件）
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("id")] = flutter::EncodableValue(instance_id);
    payload[flutter::EncodableValue("textureId")] =
        flutter::EncodableValue(texture_id);
    result->Success(flutter::EncodableValue(payload));
    return;
  }

  // 其余方法都要带 id，只操作自己的实例
  const int64_t instance_id = GetIntArg(args, "id", -1);
  Instance* inst = Find(instance_id);

  if (method == "setSize") {
    double w = 0, h = 0;
    if (inst && inst->renderer && GetDoubleArg(args, "width", &w) &&
        GetDoubleArg(args, "height", &h)) {
      inst->renderer->Resize(static_cast<int>(w), static_cast<int>(h));
    }
    result->Success();
    return;
  }

  if (method == "setPaused") {
    if (inst && inst->renderer && args) {
      auto it = args->find(flutter::EncodableValue("paused"));
      if (it != args->end()) {
        if (const auto* v = std::get_if<bool>(&it->second)) {
          inst->renderer->SetPaused(*v);
        }
      }
    }
    result->Success();
    return;
  }

  if (method == "dispose") {
    // **只销毁自己这个实例** —— 以前是无条件销毁全局实例，
    // 于是分栏卸载时会把演示页刚建好的实例一起干掉（两边都空白）。
    auto it = instances_.find(instance_id);
    if (it != instances_.end()) {
      std::unique_ptr<Instance> dying = std::move(it->second);
      instances_.erase(it);
      Instance* raw = dying.get();
      if (raw->renderer) {
        raw->renderer->SetOnFrameAvailable(nullptr);
        raw->renderer->Stop();
        raw->renderer.reset();
      }
      DestroyTexture(raw);
    }
    result->Success();
    return;
  }

  if (method == "loadModel") {
    std::string dir, file;
    if (!inst || !inst->renderer) {
      result->Error("renderer", "需先 create");
      return;
    }
    if (!GetStringArg(args, "dir", &dir) || !GetStringArg(args, "file", &file)) {
      result->Error("bad_args", "loadModel 需要字符串 dir/file");
      return;
    }
    result->Success(flutter::EncodableValue(inst->renderer->LoadModel(dir, file)));
    return;
  }

  if (method == "setZoom") {
    double zoom = 1.0;
    if (inst && inst->renderer && GetDoubleArg(args, "zoom", &zoom)) {
      inst->renderer->SetZoom(static_cast<float>(zoom));
    }
    result->Success();
    return;
  }

  if (method == "setFitBounds") {
    double cx = 0, cy = 0, w = 0, h = 0;
    if (inst && inst->renderer && GetDoubleArg(args, "cx", &cx) &&
        GetDoubleArg(args, "cy", &cy) && GetDoubleArg(args, "w", &w) &&
        GetDoubleArg(args, "h", &h)) {
      inst->renderer->SetFitBounds(static_cast<float>(cx), static_cast<float>(cy),
                                   static_cast<float>(w), static_cast<float>(h));
    }
    result->Success();
    return;
  }

  if (method == "setParameter") {
    std::string id;
    if (inst && inst->renderer && GetStringArg(args, "id2", &id)) {
      double v = 0;
      if (GetDoubleArg(args, "value", &v)) {
        inst->renderer->SetParameter(id, static_cast<float>(v));
      }
    }
    result->Success();
    return;
  }

  if (method == "startMotion") {
    std::string group;
    if (inst && inst->renderer && GetStringArg(args, "group", &group)) {
      const int index = static_cast<int>(GetIntArg(args, "index", 0));
      const int priority = static_cast<int>(GetIntArg(args, "priority", 1));
      inst->renderer->StartMotion(group, index, priority);
    }
    result->Success();
    return;
  }

  // 尚未实现的能力
  result->NotImplemented();
}

}  // namespace flutter_live2d_windows
