#pragma once

// Windows 版日志：替代 Android 的 __android_log_print。
// 输出到调试器（DebugView 可见）+ stdout。
#include <windows.h>

#include <cstdarg>
#include <cstdio>

inline void L2DLog(const char* fmt, ...)
{
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    OutputDebugStringA(buf);
    printf("%s\n", buf);
}

#define L2DLOG(...) L2DLog(__VA_ARGS__)
