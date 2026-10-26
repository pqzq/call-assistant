#pragma once

#include <string>
#include <CubismFramework.hpp>
#include <Type/CubismBasicType.hpp>

// Windows 版平台适配：文件读取走标准文件 I/O（模型目录由 Dart 传绝对路径），
// Cubism shader 走内嵌字符串表（win_shaders_data.h，桌面 Standard 版）。
class Live2DPal
{
public:
    // Signature matches csmLoadFileFunction: value (not reference) required for function pointer
    static Csm::csmByte* LoadFileAsBytes(const std::string filePath, Csm::csmSizeInt* outSize);
    static void          ReleaseBytes(Csm::csmByte* bytes);

    static Csm::csmFloat32 GetDeltaTime();
    static void            UpdateTime();

    static void PrintLogLn(const Csm::csmChar* format, ...);

private:
    static double        s_currentFrame;
    static double        s_lastFrame;
    static double        s_deltaTime;

    static double GetSystemTime();
};
