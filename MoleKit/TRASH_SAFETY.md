# Home Trash snapshot executor

`HomeTrashService` is independent of Mole cleanup. Its public initializer selects only the
current user's home `.Trash`. There is no public arbitrary-path executor, shell cleanup,
Finder Empty Trash call, recursive `removeItem`, copy/delete fallback, or elevated process.

## Caller contract

Run synchronous service calls off the main actor. Present a complete `TrashSnapshot`, including
its scope and logical-size caveat, and obtain fresh explicit permanent-deletion confirmation
before passing that exact snapshot to `execute`. A changed snapshot requires another review.
Cancellation must be propagated into `TrashCancellationToken`; await `execute` returning
before app termination, legacy Trash handover/recovery, or another filesystem operation.

The app must reciprocally gate legacy cleanup/handover and this service whenever either has
active work or an unresolved recovery journal. `recoveryStatus()` is read-only. `recover()`
restores or preserves remaining captured data and never resumes permanent deletion.

## Scope and scan bounds

- The root and every opened directory use no-follow descriptor-relative access.
- Root ownership and filesystem are verified. Every entry must have the expected owner/device.
- Hidden names are included. Symlinks are leaves; their targets are never enumerated.
- Regular files, directories, and symlinks are supported. Unknown types, invalid/ambiguous
  UTF-8 names, permission errors, disappearing entries, and incomplete scans fail closed.
- Default scan limits: 50,000 entries, depth 128, 16 MiB aggregate path bytes, 30 seconds.
  Cancellation and deadlines are checked throughout recursive work. Individual filesystem
  system calls cannot be interrupted by this synchronous token.
- Identity captures device, inode, owner, mode/type, size, mtime, ctime, and birth time.
- Logical bytes exclude directory metadata, include symlink length and duplicate hard-link
  sizes, and are never presented as exact reclaimed space. Hard-linked aliases can cause
  conservative rejection when an operation changes their shared metadata.

## Execution and recovery

1. Acquire the process-independent recovery lock; reject any unresolved prior run.
2. Rescan the entire reviewed manifest immediately before mutation and require equality.
3. Create same-filesystem private staging in `Library/Application Support/Nora/TrashRecovery`.
   Existing support ancestors may be 0755 but must be user-owned and not group/world writable.
   On macOS, ancestors with ACL grants and private staging with any extended ACL are rejected.
   Existing modes and ACLs are never silently modified.
4. Write and sync an immutable manifest once. Before each move or destructive transition,
   atomically publish a bounded, synced progress journal. An exclusive rename is mandatory;
   unsupported filesystems fail instead of falling back to copying or recursive deletion.
5. Capture only reviewed top-level entries. Rescan the entire staged manifest before the
   first unlink. New arrivals in home Trash remain outside the batch.
6. For each reviewed leaf, reopen verified ancestors, capture into its unique private slot,
   verify identity, journal deletion intent, and unlink only that slot. Directories are
   processed bottom-up and removed only with `rmdir`; unexpected children are preserved.
7. Count an unlink immediately after it succeeds, before directory-sync errors can occur.
   Cancel/error restores surviving candidates and top-level entries without overwriting.
   A name collision leaves data at the reported recovery location and blocks another run.

After interruption, actual slot presence reconciles a journaled move/delete intent. Recovery
does not repeat deletions. Malformed or unreadable journals/manifests block new runs. Known
private, single-link, bounded regular temporary journal files and genuinely metadata-only
orphan run directories can be cleaned without touching payload. Unknown recovery entries,
symlinks, non-empty directories, and conflicting identities are preserved for manual recovery.

## Explicit residual boundary

POSIX does not offer an atomic compare-and-unlink operation. Private staging and
capture-before-unlink narrow ordinary pathname races, but cannot promise unchanged content
against another process running as the same UID or a writer holding an already-open file
descriptor. Metadata identity is not a content hash or an exclusive content lock. No exact
disk-space reclamation claim is made, including for hard links, clones, sparse files,
compression, snapshots, or open files.

## Verification

`HomeTrashSafetyTests` creates isolated temporary fixture homes and never uses the production
initializer. It covers bounded/partial scans, hidden names, symlinks, new arrivals, same-name
and held-parent replacement, ctime changes, candidate tampering, cancellation, write/sync
errors, no-overwrite recovery collisions, abrupt-transition reconciliation, malformed journals,
metadata-only orphan recovery, compact journal size, cross-service locking, and macOS ACLs.
Linux C primitive checks do not establish Swift compilation or macOS filesystem/ACL behavior;
the native macOS test suite is required before release.
