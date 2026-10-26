#include "include/flutter_live2d_windows/flutter_live2d_windows_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_live2d_windows_plugin.h"

void FlutterLive2dWindowsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_live2d_windows::FlutterLive2dWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
