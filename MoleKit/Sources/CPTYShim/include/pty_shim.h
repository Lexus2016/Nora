#ifndef NORA_PTY_SHIM_H
#define NORA_PTY_SHIM_H

#include <sys/types.h>

/// Forks a child on a new pseudo-terminal, which becomes its controlling tty, and execs `path`.
/// Only async-signal-safe calls run between fork and exec.
/// Returns the child pid, or -1 on failure. `*master_fd` receives the master side.
pid_t nora_forkpty_exec(const char *path, char *const argv[], char *const envp[],
                        const char *cwd, unsigned short rows, unsigned short cols,
                        int *master_fd);

#endif
