//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <audioplayers_windows/audioplayers_windows_plugin.h>
#include <flutter_live2d_windows/flutter_live2d_windows_plugin_c_api.h>
#include <flutter_tts/flutter_tts_plugin.h>
#include <local_notifier/local_notifier_plugin.h>
#include <record_windows/record_windows_plugin_c_api.h>
#include <url_launcher_windows/url_launcher_windows.h>
#include <webview_flutter_windows/webview_windows_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  AudioplayersWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AudioplayersWindowsPlugin"));
  FlutterLive2dWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterLive2dWindowsPluginCApi"));
  FlutterTtsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterTtsPlugin"));
  LocalNotifierPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("LocalNotifierPlugin"));
  RecordWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("RecordWindowsPluginCApi"));
  UrlLauncherWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("UrlLauncherWindows"));
  WebviewWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WebviewWindowsPlugin"));
}
