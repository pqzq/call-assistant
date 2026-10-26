#include "Live2DPal.hpp"
#include "win_shaders_data.h"

#include <windows.h>

#include <cstdio>
#include <cstdlib>

using namespace Csm;

double Live2DPal::s_currentFrame = 0.0;
double Live2DPal::s_lastFrame    = 0.0;
double Live2DPal::s_deltaTime    = 0.0;

namespace {

// 绝对路径判定：Windows 盘符（C:\ 或 C:/）或 UNC（\\...）或 POSIX 风格 /...
bool IsAbsolutePath(const std::string& p) {
    if (p.size() >= 2 && p[1] == ':') return true;
    if (!p.empty() && (p[0] == '/' || p[0] == '\\')) return true;
    return false;
}

csmByte* ReadWholeFile(const std::string& path, csmSizeInt* outSize) {
    FILE* fp = fopen(path.c_str(), "rb");
    if (!fp) {
        *outSize = 0;
        return nullptr;
    }
    fseek(fp, 0, SEEK_END);
    const long size = ftell(fp);
    rewind(fp);
    if (size <= 0) {
        fclose(fp);
        *outSize = 0;
        return nullptr;
    }
    csmByte* buffer = new csmByte[size];
    const size_t got = fread(buffer, 1, static_cast<size_t>(size), fp);
    fclose(fp);
    if (got != static_cast<size_t>(size)) {
        delete[] buffer;
        *outSize = 0;
        return nullptr;
    }
    *outSize = static_cast<csmSizeInt>(size);
    return buffer;
}

}  // namespace

csmByte* Live2DPal::LoadFileAsBytes(const std::string filePath, csmSizeInt* outSize)
{
    // 绝对路径 → 普通文件读取（模型资源由 Dart 传绝对目录）
    if (IsAbsolutePath(filePath)) {
        return ReadWholeFile(filePath, outSize);
    }

    // 相对路径 → Cubism shader：Framework 请求形如
    // "FrameworkShaders/VertShaderSrc.vert" 或裸文件名，查内嵌表
    const std::string prefix = "FrameworkShaders/";
    const char* name = filePath.c_str();
    if (filePath.compare(0, prefix.size(), prefix) == 0) {
        name = filePath.c_str() + prefix.size();
    }
    const char* src = FindEmbeddedShader(name);
    if (!src) {
        *outSize = 0;
        return nullptr;
    }
    const size_t len = strlen(src);
    csmByte* buffer = new csmByte[len + 1];
    memcpy(buffer, src, len + 1);
    *outSize = static_cast<csmSizeInt>(len);  // Framework 按文本用，长度不含结尾 0
    return buffer;
}

void Live2DPal::ReleaseBytes(csmByte* bytes)
{
    delete[] bytes;
}

csmFloat32 Live2DPal::GetDeltaTime()
{
    return static_cast<csmFloat32>(s_deltaTime);
}

void Live2DPal::UpdateTime()
{
    s_currentFrame = GetSystemTime();
    s_deltaTime    = s_currentFrame - s_lastFrame;
    s_lastFrame    = s_currentFrame;
}

void Live2DPal::PrintLogLn(const csmChar* format, ...)
{
    (void)format;
}

double Live2DPal::GetSystemTime()
{
    // Windows UCRT 无 clock_gettime/CLOCK_MONOTONIC：用高精度计数器
    static LARGE_INTEGER freq = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return f;
    }();
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return static_cast<double>(now.QuadPart) / static_cast<double>(freq.QuadPart);
}
