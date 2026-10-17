#include "pty_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

static int prepare_pipe(int fds[2]) {
    if (pipe(fds) != 0) return errno;
    for (int i = 0; i < 2; i++) {
        /* The host may have a closed standard descriptor. Keep all pipe ends above 2. */
        if (fds[i] <= STDERR_FILENO) {
            int moved = fcntl(fds[i], F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
            if (moved < 0) return errno;
            close(fds[i]); fds[i] = moved;
        }
        if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0) return errno;
    }
    return 0;
}

pid_t nora_probe_spawn(const char *path, char *const argv[], char *const envp[],
                       int *input_fd, int *output_fd, int *error_fd) {
    int input[2] = {-1, -1}, output[2] = {-1, -1}, diagnostic[2] = {-1, -1};
    int error = prepare_pipe(input);
    if (error) goto fail;
    error = prepare_pipe(output);
    if (error) goto fail;
    error = prepare_pipe(diagnostic);
    if (error) goto fail;
    if (fcntl(input[1], F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(input[1], F_SETNOSIGPIPE, 1) < 0 ||
        fcntl(output[0], F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(diagnostic[0], F_SETFL, O_NONBLOCK) < 0) { error = errno; goto fail; }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attrs;
    error = posix_spawn_file_actions_init(&actions);
    if (error) goto fail;
    error = posix_spawnattr_init(&attrs);
    if (error) { posix_spawn_file_actions_destroy(&actions); goto fail; }
#define STEP(call) do { error = (call); if (error) goto destroy; } while (0)
    STEP(posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO));
    STEP(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO));
    STEP(posix_spawn_file_actions_adddup2(&actions, diagnostic[1], STDERR_FILENO));
    STEP(posix_spawn_file_actions_addclose(&actions, input[0]));
    STEP(posix_spawn_file_actions_addclose(&actions, input[1]));
    STEP(posix_spawn_file_actions_addclose(&actions, output[0]));
    STEP(posix_spawn_file_actions_addclose(&actions, output[1]));
    STEP(posix_spawn_file_actions_addclose(&actions, diagnostic[0]));
    STEP(posix_spawn_file_actions_addclose(&actions, diagnostic[1]));
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    STEP(posix_spawnattr_setsigmask(&attrs, &empty));
    STEP(posix_spawnattr_setsigdefault(&attrs, &defaults));
    STEP(posix_spawnattr_setpgroup(&attrs, 0));
    STEP(posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT));
    pid_t pid;
    STEP(posix_spawn(&pid, path, &actions, &attrs, argv, envp));
    posix_spawnattr_destroy(&attrs);
    posix_spawn_file_actions_destroy(&actions);
    close(input[0]); close(output[1]); close(diagnostic[1]);
    *input_fd = input[1]; *output_fd = output[0]; *error_fd = diagnostic[0];
    return pid;
destroy:
    posix_spawnattr_destroy(&attrs);
    posix_spawn_file_actions_destroy(&actions);
fail:
    for (int i = 0; i < 2; i++) {
        if (input[i] >= 0) close(input[i]);
        if (output[i] >= 0) close(output[i]);
        if (diagnostic[i] >= 0) close(diagnostic[i]);
    }
    errno = error;
    return -1;
#undef STEP
}

int nora_probe_exited(pid_t pid, int *status) {
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) != 0) return -1;
    if (info.si_pid == 0) return 0;
    *status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
    return 1;
}

int nora_probe_group_others(pid_t pid) {
    /* A full buffer is inconclusive, never a successful settlement. */
    pid_t members[4096];
    errno = 0;
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pid, members, (int)sizeof(members));
    if (bytes < 0 || (bytes == 0 && errno != 0) || bytes >= (int)sizeof(members) || bytes % (int)sizeof(pid_t) != 0) return -1;
    for (int i = 0; i < bytes / (int)sizeof(pid_t); i++) {
        if (members[i] > 0 && members[i] != pid) return 1;
    }
    return 0;
}

ssize_t nora_probe_write(int fd, const void *bytes, size_t count) {
    /* F_SETNOSIGPIPE was required before launch. Darwin's pipe EPIPE signal is process-
       directed, so temporarily blocking SIGPIPE in this thread would not protect the app. */
    return write(fd, bytes, count);
}
