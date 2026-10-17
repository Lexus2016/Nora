#define _GNU_SOURCE
#include "trash_fs.h"
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#if defined(__APPLE__)
#include <sys/acl.h>
#endif
#if defined(__linux__)
#include <sys/syscall.h>
#endif

static int component(const char *name) {
    if (!name || !*name || strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, "..")) {
        errno = EINVAL; return 0;
    }
    return 1;
}
static int close_error(int fd) { int error = errno; close(fd); errno = error; return -1; }
int nora_trash_open_directory(int parent, const char *name) {
    if (!component(name)) return -1;
    return openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}
int nora_trash_open_absolute_directory(const char *path) {
    if (!path || path[0] != '/') { errno = EINVAL; return -1; }
    char *copy = strdup(path);
    if (!copy) return -1;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { free(copy); return -1; }
    char *state = NULL;
    for (char *name = strtok_r(copy, "/", &state); name; name = strtok_r(NULL, "/", &state)) {
        int child = nora_trash_open_directory(fd, name);
        if (child < 0) { free(copy); return close_error(fd); }
        close(fd); fd = child;
    }
    free(copy); return fd;
}
static int identity(struct stat value, nora_trash_identity *output) {
    if (value.st_size < 0) { errno = EINVAL; return -1; }
    output->device = (uint64_t)value.st_dev;
    output->inode = (uint64_t)value.st_ino;
    output->owner = (uint32_t)value.st_uid;
    output->mode = (uint32_t)value.st_mode;
    output->size = (uint64_t)value.st_size;
#if defined(__APPLE__)
    output->modified_seconds = value.st_mtimespec.tv_sec;
    output->modified_nanoseconds = value.st_mtimespec.tv_nsec;
    output->changed_seconds = value.st_ctimespec.tv_sec;
    output->changed_nanoseconds = value.st_ctimespec.tv_nsec;
    output->birth_seconds = value.st_birthtimespec.tv_sec;
    output->birth_nanoseconds = value.st_birthtimespec.tv_nsec;
#else
    output->modified_seconds = value.st_mtim.tv_sec;
    output->modified_nanoseconds = value.st_mtim.tv_nsec;
    output->changed_seconds = value.st_ctim.tv_sec;
    output->changed_nanoseconds = value.st_ctim.tv_nsec;
    output->birth_seconds = 0; output->birth_nanoseconds = 0;
#endif
    return 0;
}
int nora_trash_stat(int parent, const char *name, nora_trash_identity *output) {
    struct stat value;
    if (!component(name)) return -1;
    if (fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW)) return -1;
    return identity(value, output);
}
int nora_trash_fstat(int fd, nora_trash_identity *output) {
    struct stat value;
    if (fstat(fd, &value)) return -1;
    return identity(value, output);
}
int nora_trash_mkdir(int parent, const char *name) {
    if (!component(name)) return -1;
    return mkdirat(parent, name, 0700);
}
int nora_trash_list(int fd, char **bytes, size_t *count, size_t max_bytes, size_t max_entries) {
    *bytes = NULL; *count = 0;
    /* dup shares the directory offset; openat(".") gives each enumeration its own offset. */
    int copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (copy < 0) return -1;
    DIR *stream = fdopendir(copy);
    if (!stream) return close_error(copy);
    char *buffer = NULL; size_t used = 0, entries = 0;
    int error = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(stream);
        if (!entry) { error = errno; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        size_t length = strlen(entry->d_name) + 1;
        if (++entries > max_entries || length > max_bytes - used) { error = EOVERFLOW; break; }
        char *next = realloc(buffer, used + length);
        if (!next) { error = errno; break; }
        buffer = next; memcpy(buffer + used, entry->d_name, length); used += length;
    }
    if (closedir(stream) && !error) error = errno;
    if (error) { free(buffer); errno = error; return -1; }
    *bytes = buffer; *count = used; return 0;
}
void nora_trash_free(void *value) { free(value); }
int nora_trash_rename_exclusive(int source, const char *name, int destination, const char *slot) {
    if (!component(name) || !component(slot)) return -1;
#if defined(__APPLE__)
    return renameatx_np(source, name, destination, slot, RENAME_EXCL);
#elif defined(__linux__) && defined(SYS_renameat2)
    return (int)syscall(SYS_renameat2, source, name, destination, slot, 1 /* RENAME_NOREPLACE */);
#else
    errno = ENOTSUP; return -1;
#endif
}
int nora_trash_unlink(int parent, const char *name, int directory) {
    if (!component(name)) return -1;
    return unlinkat(parent, name, directory ? AT_REMOVEDIR : 0);
}
int nora_trash_sync(int fd) { return fsync(fd); }
int nora_trash_close(int fd) { return close(fd); }
int nora_trash_lock(int directory) {
    int fd = openat(directory, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
    if (fd < 0) return -1;
    struct stat value;
    if (fstat(fd, &value)) return close_error(fd);
    if (!S_ISREG(value.st_mode) || value.st_uid != geteuid() || value.st_nlink != 1 || (value.st_mode & 0077)) {
        errno = EINVAL; return close_error(fd);
    }
    if (flock(fd, LOCK_EX | LOCK_NB)) return close_error(fd);
    return fd;
}
int nora_trash_require_no_acl(int directory) {
#if defined(__APPLE__)
    acl_t acl = acl_get_fd_np(directory, ACL_TYPE_EXTENDED);
    if (!acl) return -1; /* Unknown ACL state is not private staging. */
    acl_entry_t entry;
    errno = 0;
    int found = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
    int error = errno;
    acl_free(acl);
    if (found == -1 && error == EINVAL) return 0; /* Darwin's empty ACL result. */
    errno = found == 0 ? EACCES : error;
    return -1;
#else
    (void)directory;
    return 0; /* Non-macOS fixture builds do not establish macOS ACL safety. */
#endif
}
int nora_trash_require_no_grant_acl(int directory) {
#if defined(__APPLE__)
    acl_t acl = acl_get_fd_np(directory, ACL_TYPE_EXTENDED);
    if (!acl) return -1;
    acl_entry_t entry;
    int selector = ACL_FIRST_ENTRY;
    for (;;) {
        errno = 0;
        if (acl_get_entry(acl, selector, &entry)) {
            int error = errno; acl_free(acl);
            if (error == EINVAL) return 0;
            errno = error; return -1;
        }
        acl_tag_t tag;
        if (acl_get_tag_type(entry, &tag)) { int error = errno; acl_free(acl); errno = error; return -1; }
        /* Conservatively reject any allowance on a recovery ancestor. Common macOS
           everyone-deny-delete ACLs remain acceptable. Never silently rewrite ACLs. */
        if (tag != ACL_EXTENDED_DENY) { acl_free(acl); errno = EACCES; return -1; }
        selector = ACL_NEXT_ENTRY;
    }
#else
    (void)directory; return 0;
#endif
}
static int metadata_target(const char *target) {
    if (!target || (strcmp(target, "journal.json") && strcmp(target, "manifest.json"))) {
        errno = EINVAL; return 0;
    }
    return 1;
}
int nora_trash_write_metadata(int directory, const char *target, const char *temporary, const void *bytes, size_t count) {
    if (!metadata_target(target) || !component(temporary) || strncmp(temporary, ".journal-", 9)) { errno = EINVAL; return -1; }
    int fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    size_t offset = 0;
    while (offset < count) {
        ssize_t wrote = write(fd, (const char *)bytes + offset, count - offset);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) { if (!wrote) errno = EIO; return close_error(fd); }
        offset += (size_t)wrote;
    }
    if (fsync(fd)) return close_error(fd);
    if (close(fd)) return -1;
    if (renameat(directory, temporary, directory, target)) return -1;
    return fsync(directory);
}
int nora_trash_read_metadata(int directory, const char *target, void **bytes, size_t *count, size_t maximum) {
    *bytes = NULL; *count = 0;
    if (!metadata_target(target)) return -1;
    int fd = openat(directory, target, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -1;
    struct stat before, after;
    if (fstat(fd, &before)) return close_error(fd);
    if (!S_ISREG(before.st_mode) || before.st_uid != geteuid() || before.st_nlink != 1 ||
        (before.st_mode & 0077) || before.st_size <= 0 || (uint64_t)before.st_size > maximum) {
        errno = EINVAL; return close_error(fd);
    }
    size_t length = (size_t)before.st_size;
    char *buffer = malloc(length);
    if (!buffer) return close_error(fd);
    size_t offset = 0;
    while (offset < length) {
        ssize_t got = read(fd, buffer + offset, length - offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) { if (!got) errno = EIO; free(buffer); return close_error(fd); }
        offset += (size_t)got;
    }
    if (fstat(fd, &after)) { free(buffer); return close_error(fd); }
    if (before.st_size != after.st_size || before.st_mtime != after.st_mtime || before.st_ctime != after.st_ctime) {
        free(buffer); errno = ESTALE; return close_error(fd);
    }
    if (close(fd)) { free(buffer); return -1; }
    *bytes = buffer; *count = length; return 0;
}
int nora_trash_remove_journal_temporary(int directory, const char *name, size_t maximum) {
    if (!component(name) || strncmp(name, ".journal-", 9)) { errno = EINVAL; return -1; }
    struct stat value;
    if (fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW)) return -1;
    if (!S_ISREG(value.st_mode) || value.st_uid != geteuid() || value.st_nlink != 1 ||
        (value.st_mode & 0077) || value.st_size < 0 || (uint64_t)value.st_size > maximum) {
        errno = EINVAL; return -1;
    }
    if (unlinkat(directory, name, 0)) return -1;
    return fsync(directory);
}
