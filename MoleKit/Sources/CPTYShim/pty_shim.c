#include "pty_shim.h"

#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t nora_forkpty_exec(const char *path, char *const argv[], char *const envp[],
                        const char *cwd, unsigned short rows, unsigned short cols,
                        int *master_fd) {
    struct winsize ws = {0};
    ws.ws_row = rows;
    ws.ws_col = cols;

    // forkpty calls login_tty in the child: setsid + TIOCSCTTY, so /dev/tty is the pts.
    pid_t pid = forkpty(master_fd, NULL, NULL, &ws);
    if (pid == 0) {
        if (cwd != NULL && chdir(cwd) != 0) {
            _exit(126);
        }
        execve(path, argv, envp);
        _exit(127);
    }
    return pid;
}
