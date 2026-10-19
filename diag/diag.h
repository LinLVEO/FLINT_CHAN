// diag.h -- fltdiag.dll 的公开接口（C ABI，FLINT 里用 api 声明也能调）
//
// 干什么：给程序装一个「崩溃捕获器」。程序崩的瞬间，把现场写成人能读的
//   TXT + 机器能读的 JSON（可选 .dmp），用户拿着文件就能提交，我们照着模块+偏移定位。
//
// 编码约定：本机 Windows 默认 ANSI（简中 = GBK）。C 里传进来的字符串按 ANSI 解释，
//   写进报告前统一转 UTF-8。FLINT 的字符串字面量本来就是 GBK 字节，直接传即可。
//
// 线程约定：本库只保存"最后一次"错误/检查点（单线程够用）；多线程程序自行加锁。

#ifndef FLTDIAG_H
#define FLTDIAG_H

#ifdef __cplusplus
extern "C" {
#endif

/* 返回码 */
#define FLTDIAG_OK        0
#define FLTDIAG_ERR_ARG   1   /* 参数非法（空指针/太长） */
#define FLTDIAG_ERR_IO    2   /* 目录/文件建不出来 */

/* 安装崩溃捕获。app_name 可为 0（默认用 exe 文件名）。
 * 返回 FLTDIAG_OK 或错误码。重复调用只会更新 app_name。 */
int flt_diag_init(const char *app_name);

/* 卸载捕获（一般不用调；测试/长驻程序可调）。 */
int flt_diag_shutdown(void);

/* 改报告目录（默认 = exe 所在目录下的 fltdiag\）。必须在 init 之后、崩溃之前调。 */
int flt_diag_set_dir(const char *dir);

/* 预期内的错误：登记错误码 + 消息（消息最多 512 字节，可传 0）。
 * 崩溃报告会带上"最后一条错误"。返回 0 成功。 */
int flt_err_set(int code, const char *msg);
int flt_err_get(void);            /* 读最后错误码（0 = 没登记过） */
const char *flt_err_msg(void);    /* 读最后错误消息（可能为空串，指针归库所有） */

/* 检查点：把"最后走到哪"写进崩溃报告（最多 200 字节）。返回 0 成功。 */
int flt_checkpoint(const char *where);

/* 0xC0000005 这类 NTSTATUS 转可读名（崩溃报告与外部工具共用）。 */
const char *flt_diag_status_name(unsigned int code);

#ifdef __cplusplus
}
#endif

#endif /* FLTDIAG_H */
