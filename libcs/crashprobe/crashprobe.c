// crashprobe.c — 判定一个产物"到底崩没崩、崩在哪个异常码"，用**调试器**方式观察。
//
// 为什么需要它（2026-09-19 实测）：门里原来用 `Start-Process -Wait` 等产物的退出码，遇到
//   "产物在 OS 侧卡住"就无限期等待 —— 实测那次：空 IAT 目录的产物**1 个线程、CPU 0、
//   WaitReason = LpcReply**（控制台/CSRSS 那条路），既不崩也不退，整道 wx 门卡住 30+ 分钟，
//   外界看到的是"总门永远跑不完"。换成带调试器启动后，**异常先交给调试器**，进程不再走
//   WER / 控制台那条路 ⇒ 观察到的就是异常码本身，稳定且可判定。
//
// 用法：crashprobe.exe <product.exe> [timeout_ms]
// 输出（一行结论，便于门里正则匹配）：
//   probe: exception=0xC0000005  —— 非首次机会异常（真崩），进程已被终止
//   probe: exited code=0x000000FF —— 正常退出（可当 Run-Product 的替代）
//   probe: timeout               —— 超时（门里应当判红，而不是卡住）
//   probe: create-failed err=87  —— 起不来
// 退出码：1 = 观察到崩溃 ｜ 0 = 正常退出 ｜ 4 = 超时 ｜ 3 = 起不来 ｜ 2 = 用法错
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static void cleanup(PROCESS_INFORMATION *pi) {
  CloseHandle(pi->hThread);
  CloseHandle(pi->hProcess);
}

int main(int argc, char **argv) {
  if (argc < 2) { printf("usage: crashprobe <exe> [timeout_ms]\n"); return 2; }
  DWORD timeout = (argc > 2) ? (DWORD)atoi(argv[2]) : 20000;

  char cmd[MAX_PATH + 4];
  snprintf(cmd, sizeof(cmd), "\"%s\"", argv[1]);

  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  ZeroMemory(&pi, sizeof(pi));

  // DEBUG_ONLY_THIS_PROCESS：只调试它自己（不把子进程也拖进来）
  if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, DEBUG_ONLY_THIS_PROCESS, NULL, NULL, &si, &pi)) {
    printf("probe: create-failed err=%lu\n", GetLastError());
    return 3;
  }

  DWORD start = GetTickCount();
  DEBUG_EVENT de;
  for (;;) {
    if (GetTickCount() - start > timeout) {
      printf("probe: timeout\n");
      DebugActiveProcessStop(pi.dwProcessId);
      TerminateProcess(pi.hProcess, 0);
      cleanup(&pi);
      return 4;
    }
    if (!WaitForDebugEvent(&de, 100)) continue;

    if (de.dwDebugEventCode == EXCEPTION_DEBUG_EVENT) {
      DWORD code = de.u.Exception.ExceptionRecord.ExceptionCode;
      // 首次机会 = 进程自己可能处理（调试器要放行，否则会把正常程序的 handler 抢掉）；
      // 非首次机会 = 没人处理 ⇒ 真崩，这就是我们要的证据。
      if (de.u.Exception.dwFirstChance == 0) {
        printf("probe: exception=0x%08lX\n", (unsigned long)code);
        DebugActiveProcessStop(pi.dwProcessId);
        TerminateProcess(pi.hProcess, 0);
        cleanup(&pi);
        return 1;
      }
      // 放行给进程自己处理（不吞掉它的结构化异常处理）
      ContinueDebugEvent(de.dwProcessId, de.dwThreadId, DBG_EXCEPTION_NOT_HANDLED);
      continue;
    }
    if (de.dwDebugEventCode == EXIT_PROCESS_DEBUG_EVENT) {
      printf("probe: exited code=0x%08lX\n", (unsigned long)de.u.ExitProcess.dwExitCode);
      ContinueDebugEvent(de.dwProcessId, de.dwThreadId, DBG_CONTINUE);
      cleanup(&pi);
      return 0;
    }
    ContinueDebugEvent(de.dwProcessId, de.dwThreadId, DBG_CONTINUE);
  }
}
