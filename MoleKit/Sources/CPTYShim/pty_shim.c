#include "pty_shim.h"

#include <signal.h>
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
        // The forking thread is often a Dispatch or Swift Concurrency worker with signals
        // blocked, and exec keeps that mask. Mole stops its spinner with kill + wait, so an
        // inherited SIGTERM block hangs it. Reset the mask and dispositions, as
        // posix_spawn does with POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF.
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        struct sigaction dfl = {0};
        dfl.sa_handler = SIG_DFL;
        sigemptyset(&dfl.sa_mask);
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig != SIGKILL && sig != SIGSTOP) {
                sigaction(sig, &dfl, NULL);
            }
        }

        if (cwd != NULL && chdir(cwd) != 0) {
            _exit(126);
        }
        execve(path, argv, envp);
        _exit(127);
    }
    return pid;
}
