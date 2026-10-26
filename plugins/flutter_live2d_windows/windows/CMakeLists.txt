# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "flutter_live2d_windows")
project(${PROJECT_NAME} LANGUAGES CXX C)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "flutter_live2d_windows_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "flutter_live2d_windows_plugin.cpp"
  "flutter_live2d_windows_plugin.h"
  "renderer/live2d_render_thread.cpp"
  "renderer/live2d_render_thread.h"
  "live2d/live2d_log.h"
  "live2d/Live2DAllocator.cpp"
  "live2d/Live2DAllocator.hpp"
  "live2d/Live2DModel.cpp"
  "live2d/Live2DModel.hpp"
  "live2d/Live2DPal.cpp"
  "live2d/Live2DPal.hpp"
  "live2d/Live2DTextureManager.cpp"
  "live2d/Live2DTextureManager.hpp"
  "live2d/stb_image.h"
  "live2d/win_shaders_data.h"
)

# Cubism Framework（官方源码，CSM_TARGET_WIN_GL 分支）+ GLEW
# 只编核心 + OpenGL 渲染后端，排除 D3D9/D3D11/Vulkan/Metal（缺对应 SDK 头）
file(GLOB_RECURSE CUBISM_FRAMEWORK_ALL CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/CubismFramework/*.cpp")
set(CUBISM_FRAMEWORK_SOURCES "")
foreach(_src ${CUBISM_FRAMEWORK_ALL})
  if(_src MATCHES "/Rendering/(D3D9|D3D11|Vulkan|Metal)/")
    continue()
  endif()
  list(APPEND CUBISM_FRAMEWORK_SOURCES ${_src})
endforeach()
set(THIRD_PARTY_SOURCES
  ${CUBISM_FRAMEWORK_SOURCES}
  "third_party/glew/src/glew.c"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/flutter_live2d_windows/flutter_live2d_windows_plugin_c_api.h"
  "flutter_live2d_windows_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
  ${THIRD_PARTY_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# 源码含 UTF-8 中文注释：告诉 MSVC 按 UTF-8 读源文件/输出，避免 C4819（/WX 下变错误）
if(MSVC)
  target_compile_options(${PLUGIN_NAME} PRIVATE /utf-8)
  # 第三方代码在 /W4 /WX 下会因警告直接失败，降为无警告
  foreach(_tp_src ${THIRD_PARTY_SOURCES})
    set_source_files_properties(${_tp_src} PROPERTIES COMPILE_OPTIONS "/W0")
  endforeach()
  # stb_image.h 在 /W4 下有警告，同样降级
  set_source_files_properties("live2d/Live2DTextureManager.cpp" PROPERTIES COMPILE_OPTIONS "/W0")
endif()

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/CubismFramework"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/CubismCore/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/glew/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/live2d")
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  CSM_TARGET_WIN_GL GLEW_STATIC _CRT_SECURE_NO_WARNINGS)
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin opengl32)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  debug "${CMAKE_CURRENT_SOURCE_DIR}/third_party/CubismCore/lib/Live2DCubismCore_MDd.lib"
  optimized "${CMAKE_CURRENT_SOURCE_DIR}/third_party/CubismCore/lib/Live2DCubismCore_MD.lib")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(flutter_live2d_windows_bundled_libraries
  ""
  PARENT_SCOPE
)

# === Tests ===
# 暂无单测（渲染/纹理需要真实引擎环境，验收在 example 里人工目测）。
# 原脚手架的 getPlatformVersion 单测已随 M0 重写移除。
