// crash_c.c -- 库自测：装好捕手后空指针写，验证 .txt/.json/.dmp 三件套
#include <windows.h>
#include "../diag.h"

int main(void)
{
    flt_diag_init("crash-c-test");
    flt_checkpoint("准备空指针写");
    flt_err_set(42, "自测错误：故意制造访问违例");
    {
        int *p = 0;
        *p = 1; /* 0xC0000005 */
    }
    return 0;
}
