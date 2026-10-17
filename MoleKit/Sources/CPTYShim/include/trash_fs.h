#ifndef NORA_TRASH_FS_H
#define NORA_TRASH_FS_H
#include <stdint.h>
#include <stddef.h>

/* Narrow descriptor-relative primitives. None recursively removes a pathname. */
typedef struct {
    uint64_t device, inode, size;
    uint32_t owner, mode;
    int64_t modified_seconds, modified_nanoseconds;
    int64_t changed_seconds, changed_nanoseconds;
    int64_t birth_seconds, birth_nanoseconds;
} nora_trash_identity;

int nora_trash_open_absolute_directory(const char *path);
int nora_trash_open_directory(int parent, const char *name);
int nora_trash_stat(int parent, const char *name, nora_trash_identity *value);
int nora_trash_fstat(int descriptor, nora_trash_identity *value);
int nora_trash_mkdir(int parent, const char *name);
int nora_trash_list(int descriptor, char **bytes, size_t *count,
                    size_t maximum_bytes, size_t maximum_entries);
void nora_trash_free(void *value);
/* Atomic no-overwrite rename, or an error. Never falls back to copy/unlink. */
int nora_trash_rename_exclusive(int source, const char *name,
                               int destination, const char *slot);
int nora_trash_unlink(int parent, const char *name, int directory);
int nora_trash_sync(int descriptor);
int nora_trash_close(int descriptor);
/* Returns an open, exclusively locked descriptor, or -1. Lock persists until close. */
int nora_trash_lock(int directory);
int nora_trash_require_no_acl(int directory);
int nora_trash_require_no_grant_acl(int directory);
int nora_trash_write_metadata(int directory, const char *target, const char *temporary,
                            const void *bytes, size_t count);
int nora_trash_read_metadata(int directory, const char *target, void **bytes, size_t *count, size_t maximum);
int nora_trash_remove_journal_temporary(int directory, const char *name, size_t maximum);
#endif
