// studio_text.c - DirectWrite/Direct2D text shim for FLINT (flat C exports, no COM in FLINT)
// build: gcc -shared -O2 -o studio_text.dll studio_text.c -ld2d1 -ldwrite -lole32 -lcomdlg32
// v1.1: + clipboard / file dialogs / edge-resize cursor (tx_clip_*, tx_dlg_*, tx_edge_hook)
#include <windows.h>
#include <commdlg.h>
#include <shlobj.h>
#include <d2d1.h>
#include <dwrite.h>
#include <string.h>
#include <stdlib.h>
#include <wchar.h>

static const GUID my_IID_ID2D1Factory = { 0x06152247, 0x6f50, 0x465a, { 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 } };
static const GUID my_IID_IDWriteFactory = { 0xb859ee5a, 0xd838, 0x4b5b, { 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };
static ID2D1Factory *g_fac = NULL;
static ID2D1DCRenderTarget *g_dcrt = NULL;
static ID2D1RenderTarget *g_rt = NULL;
static IDWriteFactory *g_dw = NULL;
/* ---- 字体格式表（v1.4 修 "设置里中文字号轮一圈，正文就不见了"）----
   旧版是 16 格固定数组、只增不减：set_font 每换一次字号要建 2 个（代码字体 + 中文），
   撑满 16 格后 tx_font 一直返回 0 ⇒ 正文 tx_text 拿到 id 0 直接 return 1 什么都不画，
   而行号走的是 GDI ⇒ 屏幕上"行号还在、文字没了"。字号一轮 = 8 次 = 16 个，正好踩死。
   现在按 (face, px, weight) 去重复用；表满就淘汰**最久没被画过**的一格（age 在
   tx_font/tx_text/tx_measure 里刷新，正在用的两个 id 永远最热），并清掉排版缓存里
   引用该 id 的条目 —— 同一 id 换了字体，缓存里的 layout 还会是旧字体。 */
#define FMT_N 64
typedef struct { wchar_t face[96]; int px; int weight; IDWriteTextFormat *f; unsigned age; } FMT;
static FMT g_fmt[FMT_N];
static int g_nfmt = 0;
/* 文字抗锯齿：1 = ClearType（Windows 默认观感，小字最锐）/ 0 = 灰度 AA（深底无彩边但发软）。
   D2D 的 DC render target 只有 alphaMode=IGNORE 时才允许 ClearType ⇒ 切档要重建目标。 */
static int g_aa = 1;
static unsigned g_fmt_tick = 0;
static ID2D1SolidColorBrush *g_br[24];
static int g_br_rgb[24];
static int g_nbr = 0;

static D2D1_COLOR_F mk_color(int rgb) {
  D2D1_COLOR_F c;
  c.r = (float)(rgb & 255) / 255.0f;
  c.g = (float)((rgb >> 8) & 255) / 255.0f;
  c.b = (float)((rgb >> 16) & 255) / 255.0f;
  c.a = 1.0f;
  return c;
}

__declspec(dllexport) int tx_init(void) {
  if (g_fac != NULL) { return 0; }
  if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &my_IID_ID2D1Factory, NULL, (void **)&g_fac))) { return 1; }
  if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &my_IID_IDWriteFactory, (IUnknown **)&g_dw))) { return 2; }
  return 0;
}

static void lc_drop_id(int id);   /* 定义在排版缓存那一段之后 */

__declspec(dllexport) int tx_font(const wchar_t *face, int px, int weight) {
  IDWriteTextFormat *f = NULL;
  IDWriteTextFormat *old = NULL;
  int i;
  int slot;
  int is_new = 0;
  if (g_dw == NULL || face == NULL) { return 0; }
  if (px < 6) { px = 6; }
  if (px > 96) { px = 96; }
  if (weight < 100) { weight = 400; }
  /* 同 (face, px, weight) 复用同一个 id：换回旧字号不再新建对象 */
  for (i = 0; i < g_nfmt; i++) {
    if (g_fmt[i].px == px && g_fmt[i].weight == weight && wcscmp(g_fmt[i].face, face) == 0) {
      g_fmt[i].age = ++g_fmt_tick;
      return i + 1;
    }
  }
  if (g_nfmt < FMT_N) { slot = g_nfmt; is_new = 1; }
  else {
    slot = 0;
    for (i = 1; i < FMT_N; i++) { if (g_fmt[i].age < g_fmt[slot].age) { slot = i; } }
    old = g_fmt[slot].f;              /* 先留着：新格式建不出来就继续用旧的（有字总比没字强） */
  }
  if (FAILED(g_dw->lpVtbl->CreateTextFormat(g_dw, face, NULL, (DWRITE_FONT_WEIGHT)weight,
                                            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                            (float)px, L"", &f))) {
    if (old != NULL) { g_fmt[slot].age = ++g_fmt_tick; return slot + 1; }
    return (g_nfmt > 0) ? 1 : 0;
  }
  f->lpVtbl->SetWordWrapping(f, DWRITE_WORD_WRAPPING_NO_WRAP);
  f->lpVtbl->SetTextAlignment(f, DWRITE_TEXT_ALIGNMENT_LEADING);
  f->lpVtbl->SetParagraphAlignment(f, DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
  if (old != NULL) {
    lc_drop_id(slot + 1);             /* 旧 layout 绑在旧 format 上，必须一起作废 */
    old->lpVtbl->Release(old);
  }
  g_fmt[slot].f = f;
  g_fmt[slot].px = px;
  g_fmt[slot].weight = weight;
  wcsncpy(g_fmt[slot].face, face, 95);
  g_fmt[slot].face[95] = 0;
  g_fmt[slot].age = ++g_fmt_tick;
  if (is_new != 0) { g_nfmt++; }
  return slot + 1;
}

/* 表里有几个字体格式（探针/排障用；≥ FMT_N 说明在淘汰复用，没有泄漏） */
__declspec(dllexport) int tx_nfmt(void) { return g_nfmt; }

static ID2D1SolidColorBrush *brush_for(int rgb) {
  int i;
  D2D1_COLOR_F c;
  for (i = 0; i < g_nbr; i++) {
    if (g_br_rgb[i] == rgb) { return g_br[i]; }
  }
  if (g_nbr >= 24) { return NULL; }
  c = mk_color(rgb);
  if (FAILED(g_rt->lpVtbl->CreateSolidColorBrush(g_rt, &c, NULL, &g_br[g_nbr]))) { return NULL; }
  g_br_rgb[g_nbr] = rgb;
  g_nbr++;
  return g_br[g_nbr - 1];
}


/* ---- layout cache：CreateTextLayout 是这一层的绝对大头（实测 280 段 ≈ 148ms 里九成是它）。
   编辑器每帧的绝大多数行**没变**，所以按 (字体id, 文本) 缓存 TextLayout，命中就直接画。 ---- */
#define LC_N 512
typedef struct { unsigned hash; int id; int len; wchar_t *text; IDWriteTextLayout *lay; } LC;
static LC g_lc[LC_N];
static int g_lc_next = 0;

static unsigned hashw(const wchar_t *s, int n) {
  unsigned h = 2166136261u;
  int i;
  for (i = 0; i < n; i++) { h ^= (unsigned)s[i]; h *= 16777619u; }
  h ^= (unsigned)n * 2654435761u;
  return h;
}

/* 淘汰/reuse 同一 id 时调用：把这些 layout 连同它们的文本副本一起扔掉
   （layout 里绑着旧 format，留着就会画出旧字体） */
static void lc_drop_id(int id) {
  int i;
  for (i = 0; i < LC_N; i++) {
    if (g_lc[i].lay != NULL && g_lc[i].id == id) {
      g_lc[i].lay->lpVtbl->Release(g_lc[i].lay);
      g_lc[i].lay = NULL;
      free(g_lc[i].text);
      g_lc[i].text = NULL;
      g_lc[i].hash = 0;
      g_lc[i].len = 0;
      g_lc[i].id = 0;
    }
  }
}

static IDWriteTextLayout *layout_for(int id, const wchar_t *s, int n) {
  unsigned h = hashw(s, n) ^ ((unsigned)id * 97u);
  int i;
  int slot;
  IDWriteTextLayout *lay = NULL;
  LC *e;
  if (id < 1 || id > g_nfmt || g_fmt[id - 1].f == NULL) { return NULL; }
  for (i = 0; i < LC_N; i++) {
    if (g_lc[i].lay != NULL && g_lc[i].hash == h && g_lc[i].id == id && g_lc[i].len == n) {
      if (wmemcmp(g_lc[i].text, s, (size_t)n) == 0) { return g_lc[i].lay; }
    }
  }
  slot = g_lc_next % LC_N;
  g_lc_next++;
  e = &g_lc[slot];
  if (e->lay != NULL) { e->lay->lpVtbl->Release(e->lay); e->lay = NULL; }
  if (e->text != NULL) { free(e->text); e->text = NULL; }
  if (FAILED(g_dw->lpVtbl->CreateTextLayout(g_dw, s, (UINT32)n, g_fmt[id - 1].f, 8000.0f, 400.0f, &lay))) { return NULL; }
  e->text = (wchar_t *)malloc((size_t)(n + 1) * sizeof(wchar_t));
  if (e->text != NULL) { memcpy(e->text, s, (size_t)n * sizeof(wchar_t)); e->text[n] = 0; }
  e->hash = h;
  e->id = id;
  e->len = n;
  e->lay = lay;
  return lay;
}
__declspec(dllexport) int tx_begin(void *hdc, int w, int h) {
  RECT rc;
  if (g_fac == NULL) { return 1; }
  if (hdc == NULL) { return 2; }
  if (g_rt == NULL) {
    D2D1_RENDER_TARGET_PROPERTIES props;
    ZeroMemory(&props, sizeof(props));
    props.type = D2D1_RENDER_TARGET_TYPE_DEFAULT;
    props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    /* ClearType 只能用在"不透明"目标上（alphaMode = IGNORE）；灰度 AA 才用 PREMULTIPLIED */
    props.pixelFormat.alphaMode = (g_aa != 0) ? D2D1_ALPHA_MODE_IGNORE : D2D1_ALPHA_MODE_PREMULTIPLIED;
    props.dpiX = 0.0f;
    props.dpiY = 0.0f;
    props.usage = D2D1_RENDER_TARGET_USAGE_NONE;
    props.minLevel = D2D1_FEATURE_LEVEL_DEFAULT;
    if (FAILED(g_fac->lpVtbl->CreateDCRenderTarget(g_fac, &props, &g_dcrt))) { return 3; }
    g_rt = (ID2D1RenderTarget *)g_dcrt;
  }
  rc.left = 0;
  rc.top = 0;
  rc.right = w;
  rc.bottom = h;
  if (FAILED(g_dcrt->lpVtbl->BindDC(g_dcrt, (HDC)hdc, &rc))) { return 4; }
  if (g_aa != 0) {
    g_rt->lpVtbl->SetTextAntialiasMode(g_rt, D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
  } else {
    g_rt->lpVtbl->SetTextAntialiasMode(g_rt, D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  }
  g_rt->lpVtbl->BeginDraw(g_rt);
  return 0;
}

/* 切文字抗锯齿：1 = ClearType / 0 = 灰度。切档要丢掉 render target（alphaMode 不可改），
   下一帧 tx_begin 会按新档重建；返回生效后的档位。 */
__declspec(dllexport) int tx_aa(int mode) {
  int v = (mode != 0) ? 1 : 0;
  if (v == g_aa) { return g_aa; }
  g_aa = v;
  if (g_dcrt != NULL) {
    /* 用 IUnknown 的 Release：DCRenderTarget 的 vtbl 里 Release 继承自 IUnknown */
    ((IUnknown *)g_dcrt)->lpVtbl->Release((IUnknown *)g_dcrt);
    g_dcrt = NULL;
    g_rt = NULL;
  }
  return g_aa;
}

__declspec(dllexport) int tx_aa_get(void) { return g_aa; }

__declspec(dllexport) int tx_end(void) {
  if (g_rt == NULL) { return 1; }
  g_rt->lpVtbl->EndDraw(g_rt, NULL, NULL);
  return 0;
}

__declspec(dllexport) int tx_text(int id, int x, int y, const wchar_t *s, int n, int colorref) {
  IDWriteTextLayout *lay = NULL;
  ID2D1SolidColorBrush *br = NULL;
  D2D1_POINT_2F pt;
  if (g_rt == NULL || id < 1 || id > g_nfmt || s == NULL) { return 1; }
  g_fmt[id - 1].age = ++g_fmt_tick;      /* 正在画的 id = 最热，淘汰时不会挑到它 */
  br = brush_for(colorref);
  if (br == NULL) { return 2; }
  lay = layout_for(id, s, n);
  if (lay == NULL) { return 3; }
  pt.x = (float)x;
  pt.y = (float)y;
  g_rt->lpVtbl->DrawTextLayout(g_rt, pt, lay, (ID2D1Brush *)br, D2D1_DRAW_TEXT_OPTIONS_NONE);
  return 0;
}

__declspec(dllexport) int tx_measure(int id, const wchar_t *s, int n) {
  IDWriteTextLayout *lay = NULL;
  DWRITE_TEXT_METRICS m;
  int w = 0;
  if (g_dw == NULL || id < 1 || id > g_nfmt || s == NULL) { return 0; }
  g_fmt[id - 1].age = ++g_fmt_tick;      /* 量宽也算法"在用"（光标/排版每帧都量） */
  lay = layout_for(id, s, n);
  if (lay == NULL) { return 0; }
  ZeroMemory(&m, sizeof(m));
  lay->lpVtbl->GetMetrics(lay, &m);
  w = (int)(m.widthIncludingTrailingWhitespace + 0.5f);
  return w;
}
__declspec(dllexport) int tx_fontA(const char *face, int px, int weight) {
  wchar_t w[128];
  int n = MultiByteToWideChar(CP_UTF8, 0, face, -1, w, 128);
  if (n <= 0) { return 0; }
  return tx_font(w, px, weight);
}

/* =====================================================================
   v1.1  clipboard + file dialogs + edge-resize cursor
   All strings crossing this boundary are UTF-8 byte buffers (FLINT side).
   Everything is defensive: NULL / len<=0 / cap<=0 return 0, nothing throws.
   ===================================================================== */

/* clamp the caller's cap into something sane (0 .. 64 MiB) */
static int tx_cap(int cap) {
  if (cap < 0) { return 0; }
  if (cap > 64 * 1024 * 1024) { return 64 * 1024 * 1024; }
  return cap;
}

/* UTF-8 bytes -> wide, bounded; dst always NUL-terminated. returns wide length or -1 */
static int tx_u8_to_w(const char *s, int slen, wchar_t *dst, int dstcap) {
  int n;
  if (s == NULL || dst == NULL || dstcap <= 0) { return -1; }
  if (slen < 0) {
    int k = 0;
    while (k < 65536 && s[k] != 0) { k++; }
    slen = k;
  }
  if (slen > 65536) { slen = 65536; }
  n = MultiByteToWideChar(CP_UTF8, 0, s, slen, dst, dstcap - 1);
  if (n < 0) { return -1; }
  dst[n] = 0;
  return n;
}

/* wide -> UTF-8 bytes, clamped to cap-1 bytes + NUL. returns bytes written (>=0). */
static int tx_w_to_u8(const wchar_t *w, int wmax, char *dst, int cap) {
  int o = 0;
  int i = 0;
  if (dst == NULL || cap <= 0) { return 0; }
  dst[0] = 0;
  if (w == NULL || wmax <= 0) { return 0; }
  while (i < wmax && w[i] != 0) {
    unsigned c = (unsigned)w[i];
    if (c < 0x80) {
      if (o + 1 > cap - 1) { break; }
      dst[o] = (char)c; o += 1;
    } else if (c < 0x800) {
      if (o + 2 > cap - 1) { break; }
      dst[o] = (char)(0xC0 | (c >> 6)); o += 1;
      dst[o] = (char)(0x80 | (c & 0x3F)); o += 1;
    } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < wmax && w[i + 1] >= 0xDC00 && w[i + 1] <= 0xDFFF) {
      unsigned cp = 0x10000u + (((c - 0xD800u) << 10) | ((unsigned)w[i + 1] - 0xDC00u));
      if (o + 4 > cap - 1) { break; }
      dst[o] = (char)(0xF0 | (cp >> 18)); o += 1;
      dst[o] = (char)(0x80 | ((cp >> 12) & 0x3F)); o += 1;
      dst[o] = (char)(0x80 | ((cp >> 6) & 0x3F)); o += 1;
      dst[o] = (char)(0x80 | (cp & 0x3F)); o += 1;
      i += 1;
    } else {
      /* BMP char, and lone surrogates (D800-DFFF) become U+FFFD so output stays valid UTF-8 */
      if (c >= 0xD800 && c <= 0xDFFF) { c = 0xFFFD; }
      if (o + 3 > cap - 1) { break; }
      dst[o] = (char)(0xE0 | (c >> 12)); o += 1;
      dst[o] = (char)(0x80 | ((c >> 6) & 0x3F)); o += 1;
      dst[o] = (char)(0x80 | (c & 0x3F)); o += 1;
    }
    i += 1;
  }
  dst[o] = 0;
  return o;
}

/* OpenClipboard with a few retries (another process may hold it for a few ms). */
static int tx_clip_open(void) {
  int i;
  for (i = 0; i < 10; i++) {
    if (OpenClipboard(NULL)) { return 1; }
    Sleep(10);
  }
  return 0;
}

__declspec(dllexport) int tx_clip_put(const char *utf8, int len) {
  wchar_t *w = NULL;
  int wl = 0;
  int ok = 0;
  int unicode_ok = 0;
  HANDLE h;
  if (utf8 == NULL || len <= 0) { return 0; }
  if (len > 16 * 1024 * 1024) { return 0; }
  wl = MultiByteToWideChar(CP_UTF8, 0, utf8, len, NULL, 0);
  if (wl <= 0) { return 0; }
  w = (wchar_t *)malloc(((size_t)wl + 1) * sizeof(wchar_t));
  if (w == NULL) { return 0; }
  if (MultiByteToWideChar(CP_UTF8, 0, utf8, len, w, wl) != wl) { free(w); return 0; }
  w[wl] = 0;
  if (!tx_clip_open()) { free(w); return 0; }
  if (!EmptyClipboard()) { CloseClipboard(); free(w); return 0; }
  /* CF_UNICODETEXT: the preferred format (real Unicode, no codepage loss) */
  h = GlobalAlloc(GMEM_MOVEABLE, ((size_t)wl + 1) * sizeof(wchar_t));
  if (h != NULL) {
    void *p = GlobalLock(h);
    if (p != NULL) {
      memcpy(p, w, ((size_t)wl + 1) * sizeof(wchar_t));
      GlobalUnlock(h);
      if (SetClipboardData(CF_UNICODETEXT, h) != NULL) {
        h = NULL;                 /* clipboard owns it now */
        unicode_ok = 1;
      }
    }
    if (h != NULL) { GlobalFree(h); }
  }
  /* CF_TEXT: ACP fallback for legacy apps (cheap: reuse the wide buffer) */
  if (wl <= 8 * 1024 * 1024) {
    int al = WideCharToMultiByte(CP_ACP, 0, w, wl, NULL, 0, NULL, NULL);
    if (al > 0) {
      char *a = (char *)malloc((size_t)al + 1);
      if (a != NULL) {
        if (WideCharToMultiByte(CP_ACP, 0, w, wl, a, al, NULL, NULL) == al) {
          a[al] = 0;
          h = GlobalAlloc(GMEM_MOVEABLE, (size_t)al + 1);
          if (h != NULL) {
            void *p = GlobalLock(h);
            if (p != NULL) {
              memcpy(p, a, (size_t)al + 1);
              GlobalUnlock(h);
              if (SetClipboardData(CF_TEXT, h) != NULL) { h = NULL; ok = 1; }
            }
            if (h != NULL) { GlobalFree(h); }
          }
        }
        free(a);
      }
    }
  }
  CloseClipboard();
  free(w);
  return (unicode_ok || ok) ? 1 : 0;
}

__declspec(dllexport) int tx_clip_get(char *buf, int cap) {
  int n = -1;
  HANDLE h;
  cap = tx_cap(cap);
  if (buf == NULL || cap <= 0) { return 0; }
  buf[0] = 0;
  if (!tx_clip_open()) { return 0; }
  /* 1st choice: CF_UNICODETEXT */
  h = GetClipboardData(CF_UNICODETEXT);
  if (h != NULL) {
    const wchar_t *w = (const wchar_t *)GlobalLock(h);
    if (w != NULL) {
      SIZE_T bytes = GlobalSize(h);
      int wmax = (int)(bytes / sizeof(wchar_t));
      if (wmax > cap) { wmax = cap; }      /* >=1 UTF-8 byte per unit -> cap is enough */
      n = tx_w_to_u8(w, wmax, buf, cap);
      GlobalUnlock(h);                     /* never leave the handle locked */
    }
  }
  /* fallback: CF_TEXT (ACP bytes) -> UTF-8 */
  if (n < 0) {
    h = GetClipboardData(CF_TEXT);
    if (h != NULL) {
      const char *a = (const char *)GlobalLock(h);
      if (a != NULL) {
        SIZE_T bytes = GlobalSize(h);
        int alen = (int)bytes;
        if (alen > cap * 2) { alen = cap * 2; }  /* ACP char <= 2 bytes -> enough for cap UTF-8 */
        if (alen > 0) {
          wchar_t *w = (wchar_t *)malloc(((size_t)alen + 1) * sizeof(wchar_t));
          if (w != NULL) {
            int wl = MultiByteToWideChar(CP_ACP, 0, a, alen, w, alen);
            if (wl >= 0) {
              w[wl] = 0;
              n = tx_w_to_u8(w, wl, buf, cap);
            }
            free(w);
          }
        }
        GlobalUnlock(h);
      }
    }
  }
  CloseClipboard();
  if (n < 0) { buf[0] = 0; return 0; }
  return n;
}

/* current directory as wide text; 1 = ok */
static int tx_cur_dir(wchar_t *dir, int cap) {
  DWORD n;
  if (dir == NULL || cap <= 0) { return 0; }
  dir[0] = 0;
  n = GetCurrentDirectoryW((DWORD)cap, dir);
  if (n == 0 || n >= (DWORD)cap) { dir[0] = 0; return 0; }
  return 1;
}

/* FLINT 源码 (*.fl) / 所有文件 (*.*) -- ASCII-only C source via \u escapes */
static const wchar_t TX_FILTER[] =
  L"FLINT \u6e90\u7801 (*.fl)\0*.fl\0\u6240\u6709\u6587\u4ef6 (*.*)\0*.*\0";

static int tx_dlg_common(void *hwnd, char *buf, int cap, int save, const char *defname, const char *initdir) {
  OPENFILENAMEW ofn;
  wchar_t file[1024];
  wchar_t dir[1024];
  wchar_t init[1024];
  int hasinit = 0;
  int i;
  cap = tx_cap(cap);
  if (buf == NULL || cap <= 0) { return 0; }
  buf[0] = 0;
  file[0] = 0;
  if (initdir != NULL && initdir[0] != 0) {
    init[0] = 0;
    /* v1.2 (2026-10-27): the caller can pin the dialog's starting folder ("last location used"),
       otherwise we keep the old behaviour (process CWD). */
    hasinit = (tx_u8_to_w(initdir, -1, init, 1024) > 0) ? 1 : 0;
  }
  if (defname != NULL && defname[0] != 0) {
    int dl = 0;
    while (dl < 4096 && defname[dl] != 0) { dl++; }
    tx_u8_to_w(defname, dl, file, 1024);
    for (i = 0; i < 1024 && file[i] != 0; i++) {
      if (file[i] == L'/' || file[i] == L'\\' || file[i] == L':' ||
          file[i] == L'*' || file[i] == L'?' || file[i] == L'"' ||
          file[i] == L'<' || file[i] == L'>' || file[i] == L'|') { file[i] = L'_'; }
    }
  }
  ZeroMemory(&ofn, sizeof(ofn));
  ofn.lStructSize = sizeof(ofn);
  ofn.hwndOwner = (HWND)hwnd;
  ofn.lpstrFilter = TX_FILTER;
  ofn.lpstrFile = file;
  ofn.nMaxFile = 1024;
  if (hasinit) { ofn.lpstrInitialDir = init; }
  else { ofn.lpstrInitialDir = tx_cur_dir(dir, 1024) ? dir : NULL; }
  if (save) {
    ofn.lpstrDefExt = L"fl";
    ofn.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
  } else {
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
  }
  if (save ? !GetSaveFileNameW(&ofn) : !GetOpenFileNameW(&ofn)) { return 0; }
  tx_w_to_u8(file, 1024, buf, cap);
  return (buf[0] != 0) ? 1 : 0;
}

__declspec(dllexport) int tx_dlg_open(void *hwnd, char *buf, int cap) {
  return tx_dlg_common(hwnd, buf, cap, 0, NULL, NULL);
}

__declspec(dllexport) int tx_dlg_save(void *hwnd, char *buf, int cap, const char *defname) {
  return tx_dlg_common(hwnd, buf, cap, 1, defname, NULL);
}

/* v1.2 (2026-10-27): same as above but with an explicit starting folder (UTF-8, ""/NULL = CWD).
   Old exports stay untouched so already-built apps / probes keep working byte-for-byte. */
__declspec(dllexport) int tx_dlg_open2(void *hwnd, char *buf, int cap, const char *initdir) {
  return tx_dlg_common(hwnd, buf, cap, 0, NULL, initdir);
}

__declspec(dllexport) int tx_dlg_save2(void *hwnd, char *buf, int cap, const char *defname, const char *initdir) {
  return tx_dlg_common(hwnd, buf, cap, 1, defname, initdir);
}

/* ---- folder picker: "open folder" = workspace root (2026-10-26) ----
   GetOpenFileNameW cannot pick directories, and the FLINT side has no COM, so the
   shell's own browser dialog does the work here. BIF_NEWDIALOGSTYLE gives the modern
   resizable picker; SHGetPathFromIDListW returns a wide path which we hand back as UTF-8.

   v1.2 (2026-10-27): tx_dlg_folder2 also takes a starting folder. SHBrowseForFolder has no
   "initial dir" field -- the documented way is the BFFM_INITIALIZED callback + BFFM_SETSELECTION. */
static int CALLBACK tx_browse_cb(HWND h, UINT msg, LPARAM lp, LPARAM data) {
  (void)lp;
  if (msg == BFFM_INITIALIZED && data != 0) {
    SendMessageW(h, BFFM_SETSELECTIONW, TRUE, data);
  }
  return 0;
}

__declspec(dllexport) int tx_dlg_folder2(void *hwnd, char *buf, int cap, const char *initdir) {
  BROWSEINFOW bi;
  LPITEMIDLIST pidl = NULL;
  wchar_t path[1024];
  wchar_t init[1024];
  int hasinit = 0;
  int ok = 0;
  cap = tx_cap(cap);
  if (buf == NULL || cap <= 0) { return 0; }
  buf[0] = 0;
  init[0] = 0;
  if (initdir != NULL && initdir[0] != 0) {
    hasinit = (tx_u8_to_w(initdir, -1, init, 1024) > 0) ? 1 : 0;
  }
  ZeroMemory(&bi, sizeof(bi));
  bi.hwndOwner = (HWND)hwnd;
  bi.lpszTitle = L"Select workspace folder";
  bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_EDITBOX;
  if (hasinit) {
    bi.lpfn = (BFFCALLBACK)tx_browse_cb;
    bi.lParam = (LPARAM)init;
  }
  pidl = SHBrowseForFolderW(&bi);
  if (pidl != NULL) {
    path[0] = 0;
    if (SHGetPathFromIDListW(pidl, path)) {
      tx_w_to_u8(path, 1024, buf, cap);
      ok = (buf[0] != 0) ? 1 : 0;
    }
    CoTaskMemFree(pidl);
  }
  return ok;
}

__declspec(dllexport) int tx_dlg_folder(void *hwnd, char *buf, int cap) {
  return tx_dlg_folder2(hwnd, buf, cap, NULL);
}

/* ---- persistent shell (v1.3, 2026-10-27) ----
   Why: the old built-in terminal ran every line as a fresh `cmd /c`, so `cd` never stuck and
   nothing could stream. This keeps ONE cmd.exe alive behind pipes:
     tx_sh_start(cwd)   spawn  cmd /Q /D /K "chcp 65001>nul"   with stdin/stdout/stderr on pipes
     tx_sh_write(s, n)  write the command bytes + CRLF
     tx_sh_read(buf,n)  non-blocking read of whatever is available (PeekNamedPipe first)
     tx_sh_alive()      1 while the child lives
     tx_sh_stop()       kill + close everything
   Not a real console: no cursor addressing, no Ctrl+C / no window resize (that would need ConPTY),
   but `cd`, env vars, builtins and streaming output behave like a shell -- i.e. the part people
   actually use in an editor's terminal. chcp 65001 = have cmd emit UTF-8 so the bytes go straight
   into the FLINT layer's UTF-8 buffer. */
static HANDLE g_sh_in = NULL;
static HANDLE g_sh_out = NULL;
static HANDLE g_sh_proc = NULL;

__declspec(dllexport) int tx_sh_start(const char *cwd_utf8) {
  SECURITY_ATTRIBUTES sa;
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  HANDLE inR = NULL, inW = NULL, outR = NULL, outW = NULL;
  wchar_t cwdW[1024];
  wchar_t cmd[] = L"cmd.exe /Q /D /K \"chcp 65001>nul\"";
  if (g_sh_proc != NULL) { return 1; }
  sa.nLength = sizeof(sa);
  sa.lpSecurityDescriptor = NULL;
  sa.bInheritHandle = TRUE;
  if (!CreatePipe(&inR, &inW, &sa, 0)) { return 0; }
  if (!SetHandleInformation(inW, HANDLE_FLAG_INHERIT, 0)) { CloseHandle(inR); CloseHandle(inW); return 0; }
  if (!CreatePipe(&outR, &outW, &sa, 0)) { CloseHandle(inR); CloseHandle(inW); return 0; }
  if (!SetHandleInformation(outR, HANDLE_FLAG_INHERIT, 0)) {
    CloseHandle(inR); CloseHandle(inW); CloseHandle(outR); CloseHandle(outW); return 0;
  }
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  si.hStdInput = inR;
  si.hStdOutput = outW;
  si.hStdError = outW;
  cwdW[0] = 0;
  if (cwd_utf8 != NULL && cwd_utf8[0] != 0) { tx_u8_to_w(cwd_utf8, -1, cwdW, 1024); }
  ZeroMemory(&pi, sizeof(pi));
  if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL,
                      (cwdW[0] != 0) ? cwdW : NULL, &si, &pi)) {
    CloseHandle(inR); CloseHandle(inW); CloseHandle(outR); CloseHandle(outW);
    return 0;
  }
  CloseHandle(inR);
  CloseHandle(outW);
  CloseHandle(pi.hThread);
  g_sh_in = inW;
  g_sh_out = outR;
  g_sh_proc = pi.hProcess;
  return 1;
}

__declspec(dllexport) int tx_sh_write(const char *s, int n) {
  DWORD wrote = 0;
  if (g_sh_in == NULL) { return 0; }
  if (s != NULL && n > 0) {
    if (!WriteFile(g_sh_in, s, (DWORD)n, &wrote, NULL)) { return 0; }
  }
  if (!WriteFile(g_sh_in, "\r\n", 2, &wrote, NULL)) { return 0; }
  return 1;
}

__declspec(dllexport) int tx_sh_read(char *buf, int cap) {
  DWORD avail = 0;
  DWORD got = 0;
  if (g_sh_out == NULL || buf == NULL || cap <= 0) { return 0; }
  if (!PeekNamedPipe(g_sh_out, NULL, 0, NULL, &avail, NULL)) { return -1; }
  if (avail == 0) { return 0; }
  if (avail > (DWORD)cap) { avail = (DWORD)cap; }
  if (!ReadFile(g_sh_out, buf, avail, &got, NULL)) { return -1; }
  return (int)got;
}

__declspec(dllexport) int tx_sh_alive(void) {
  DWORD code = 0;
  if (g_sh_proc == NULL) { return 0; }
  if (GetExitCodeProcess(g_sh_proc, &code) && code == STILL_ACTIVE) { return 1; }
  return 0;
}

__declspec(dllexport) int tx_sh_stop(void) {
  if (g_sh_proc != NULL) { TerminateProcess(g_sh_proc, 0); CloseHandle(g_sh_proc); g_sh_proc = NULL; }
  if (g_sh_in != NULL) { CloseHandle(g_sh_in); g_sh_in = NULL; }
  if (g_sh_out != NULL) { CloseHandle(g_sh_out); g_sh_out = NULL; }
  return 1;
}

/* ---- edge-resize cursor: window-procedure subclass ----
   The FLINT window is a borderless WS_POPUP whose own wndproc forces the arrow on
   WM_SETCURSOR. We sit in front of it: near an edge/corner we SetCursor the stock
   resize cursor and return 1; every other message is chained unchanged. */
static WNDPROC g_edge_old = NULL;
static int g_edge_margin = 0;

static LRESULT CALLBACK tx_edge_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_SETCURSOR && g_edge_margin > 0) {
    POINT pt;
    RECT rc;
    if (GetCursorPos(&pt) && ScreenToClient(h, &pt) && GetClientRect(h, &rc)) {
      int w = rc.right - rc.left;
      int ht = rc.bottom - rc.top;
      int m = g_edge_margin;
      int left = (pt.x < m);
      int right = (pt.x >= w - m);
      int top = (pt.y < m);
      int bottom = (pt.y >= ht - m);
      int id = 0;
      if (left && top) { id = 32642; }            /* IDC_SIZENWSE */
      else if (right && bottom) { id = 32642; }
      else if (right && top) { id = 32643; }      /* IDC_SIZENESW */
      else if (left && bottom) { id = 32643; }
      else if (left || right) { id = 32644; }     /* IDC_SIZEWE  */
      else if (top || bottom) { id = 32645; }     /* IDC_SIZENS  */
      if (id != 0) {
        HCURSOR c = LoadCursorA(NULL, MAKEINTRESOURCEA(id));
        if (c != NULL) { SetCursor(c); return 1; }
      }
    }
  }
  if (g_edge_old == NULL) { return DefWindowProcA(h, msg, wp, lp); }
  return CallWindowProcA(g_edge_old, h, msg, wp, lp);
}

__declspec(dllexport) int tx_edge_hook(void *hwnd, int margin) {
  LONG_PTR old;
  if (hwnd == NULL) { return 0; }
  if (margin < 0) { margin = 0; }
  if (margin > 64) { margin = 64; }
  SetLastError(0);
  old = SetWindowLongPtrA((HWND)hwnd, GWLP_WNDPROC, (LONG_PTR)tx_edge_proc);
  if (old == 0 && GetLastError() != 0) { return 0; }
  if ((WNDPROC)old == tx_edge_proc) {
    /* already subclassed by us: keep the original proc (no self-recursion) */
    g_edge_margin = margin;
    return 1;
  }
  g_edge_old = (WNDPROC)old;
  g_edge_margin = margin;
  return 1;
}