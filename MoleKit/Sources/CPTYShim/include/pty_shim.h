#ifndef NORA_PTY_SHIM_H
#define NORA_PTY_SHIM_H

#include <sys/types.h>

/// Forks a child on a new pseudo-terminal, which becomes its controlling tty, and execs `path`.
/// Only async-signal-safe calls run between fork and exec.
/// Returns the child pid, or -1 on failure. `*master_fd` receives the master side.
pid_t nora_forkpty_exec(const char *path, char *const argv[], char *const envp[],
                        const char *cwd, unsigned short rows, unsigned short cols,
                        int *master_fd);


/* A pipe child in a new, owned process group. Parent ends are nonblocking. */
pid_t nora_probe_spawn(const char *path, char *const argv[], char *const envp[],
                       int *input_fd, int *output_fd, int *error_fd);
/* Observes exit without reaping: the reserved PID pins process-group ownership. */
int nora_probe_exited(pid_t pid, int *status);
/* 0 means only the reserved leader remains; -1 means inspection failed. */
int nora_probe_group_others(pid_t pid);
/* Writes without changing the application's process-wide SIGPIPE disposition. */
ssize_t nora_probe_write(int fd, const void *bytes, size_t count);

#endif
