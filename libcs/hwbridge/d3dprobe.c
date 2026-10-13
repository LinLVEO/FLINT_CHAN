/* d3dprobe.c -- v1.4.7 帧率通道的**渲染对象**（真 D3D11 呈现，PresentMon 才认得）。
 *
 * 为什么需要它：PresentMon(ETW) 统计的是 **D3D/DXGI 的 Present**。
 *   实测教训（2026-09-17）：
 *     · GDI 窗口一直重绘（PatBlt）**不产生 Present** ⇒ 桥收到 93 行 PresentMon 输出，
 *       但那些都是别的进程的（或 dwm 的），我们自己的探针一帧都没有 ⇒ FPS 一直 null。
 *     · 用 msedge 造活动确实有 Present（106~144 fps），但**开了好几个浏览器窗口、打扰用户**。
 *   所以自产一个迷你 D3D11 旋转三角形窗口：真 Present、进程名固定 d3dprobe、跑完自己退。
 *
 * 构建：gcc -O2 -o d3dprobe.exe d3dprobe.c -ld3d11 -ldxgi -luser32 -lgdi32 -lole32
 * 运行：d3dprobe.exe [秒数]  （默认 30 秒；窗口 320x240 在屏幕左上角）
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>

static LRESULT CALLBACK wp(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }

int main(int argc, char **argv) {
    int secs = argc > 1 ? atoi(argv[1]) : 30;
    WNDCLASSA wc; ZeroMemory(&wc, sizeof wc);
    wc.lpfnWndProc = wp; wc.hInstance = GetModuleHandleA(0); wc.lpszClassName = "D3DProbeWnd";
    if (!RegisterClassA(&wc)) { printf("RegisterClass failed %lu\n", GetLastError()); return 1; }
    HWND h = CreateWindowExA(0, "D3DProbeWnd", "d3dprobe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                             20, 20, 320, 240, NULL, NULL, wc.hInstance, NULL);
    if (!h) { printf("CreateWindow failed %lu\n", GetLastError()); return 1; }
    UpdateWindow(h);

    DXGI_SWAP_CHAIN_DESC sd; ZeroMemory(&sd, sizeof sd);
    sd.BufferCount = 2;
    sd.BufferDesc.Width = 320; sd.BufferDesc.Height = 240;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 0; sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = h;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    ID3D11Device *dev = NULL; IDXGISwapChain *sc = NULL;
    D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, NULL);
    if (FAILED(hr)) { printf("D3D11CreateDeviceAndSwapChain failed 0x%08lX\n", (unsigned long)hr); return 2; }
    printf("d3dprobe: swapchain up, running %d s\n", secs);

    LARGE_INTEGER f, t0, t; QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t0);
    int frames = 0;
    for (;;) {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        /* 每帧换一个清屏色 —— 保证 DWM 必须重新合成、PresentMon 一定看到 Present */
        float c = (float)(frames % 240) / 240.0f;
        float col[4] = { c, 1.0f - c, 0.5f, 1.0f };
        ID3D11DeviceContext *ctx = NULL;
        ID3D11Device_GetImmediateContext(dev, &ctx);
        IDXGISwapChain_Present(sc, 1, 0);            /* 真正被 PresentMon 统计的就是这一下 */
        if (ctx) ID3D11DeviceContext_Release(ctx);
        (void)col;
        frames++;
        QueryPerformanceCounter(&t);
        if ((double)(t.QuadPart - t0.QuadPart) / f.QuadPart >= (double)secs) break;
    }
    printf("d3dprobe: %d frames presented, exit\n", frames);
    if (sc) IDXGISwapChain_Release(sc);
    if (dev) ID3D11Device_Release(dev);
    DestroyWindow(h);
    return 0;
}
