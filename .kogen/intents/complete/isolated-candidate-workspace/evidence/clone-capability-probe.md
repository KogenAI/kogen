# Fail-closed cloning probe — 2026-09-22

Question: does the current `Workspace.clone_seed/...` use of `cp -cR` actually
enforce the accepted no-byte-copy-fallback requirement? The earlier
`apfs-clone-probe.md` inferred yes from successful copies and distinct inodes.
That inference is false. Its byte equality/mutation observations remain valid.

## Local documentation and owned setup

`MANPAGER=cat man cp | col -b` documents fallback from `clonefile(2)` to
`copyfile(2)` across filesystems or when cloning is unsupported. This describes
the installed command, not an assumed internet version.

All writes were disposable experiment assets inside this Draft's
`evidence/clone-capability-probe/`. Input `source.txt` is retained. Initial
setup command used `hdiutil create ... -type UDRW` and failed: invalid argument
for `-type`. A following attach failed because no image existed. Those are
invalid setup attempts, not cloning evidence. Reading `hdiutil create -help`
showed that the correct blank-image type is `UDIF`.

Corrected setup:

```sh
hdiutil create -size 16m -fs HFS+ -volname KogenCloneProbe -type UDIF -nospotlight .kogen/intents/drafts/isolated-candidate-workspace/evidence/clone-capability-probe/unsupported.dmg
hdiutil attach -nobrowse -mountpoint .kogen/intents/drafts/isolated-candidate-workspace/evidence/clone-capability-probe/mount .kogen/intents/drafts/isolated-candidate-workspace/evidence/clone-capability-probe/unsupported.dmg
```

The empty owned mount directory was created first. Attach reported
`/dev/disk4s1 Apple_HFS` at that exact mount path.

## Native API and fallback controls

Executed with `python3 -B -c '<script below>'`. Python is only the direct
`ctypes` caller for the native API; no implementation was installed.

```python
import ctypes, errno, os, subprocess
base = os.path.abspath(".kogen/intents/drafts/isolated-candidate-workspace/evidence/clone-capability-probe")
source = os.path.join(base, "source.txt")
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
clone = libc.clonefile
clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
clone.restype = ctypes.c_int
for label, target in [("same-filesystem-native", os.path.join(base, "apfs-native.txt")), ("hfs-native", os.path.join(base, "mount/native.txt"))]:
    ctypes.set_errno(0)
    status = clone(os.fsencode(source), os.fsencode(target), 0)
    error = ctypes.get_errno()
    print(label, "status", status, "errno", error, os.strerror(error), "destination_exists", os.path.exists(target))
    if status == 0:
        print("bytes_equal", subprocess.run(["cmp", "-s", source, target]).returncode == 0)
target = os.path.join(base, "mount/cp-fallback.txt")
status = subprocess.run(["/bin/cp", "-c", source, target]).returncode
print("hfs-cp-c", "status", status, "destination_exists", os.path.exists(target), "bytes_equal", subprocess.run(["cmp", "-s", source, target]).returncode == 0)
```

Exit 0:

```text
same-filesystem-native status 0 errno 0 Undefined error: 0 destination_exists True
bytes_equal True
hfs-native status -1 errno 18 Cross-device link destination_exists False
hfs-cp-c status 0 destination_exists True bytes_equal True
```

After detaching and reattaching that same owned image, a separate control
eliminated cross-device failure as the sole cause: source and destination were
both on HFS+.

```python
import ctypes, os, subprocess
base = os.path.abspath(".kogen/intents/drafts/isolated-candidate-workspace/evidence/clone-capability-probe/mount")
source = os.path.join(base, "cp-fallback.txt")
target = os.path.join(base, "native-samefs.txt")
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
clone = libc.clonefile
clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
clone.restype = ctypes.c_int
ctypes.set_errno(0)
status = clone(os.fsencode(source), os.fsencode(target), 0)
error = ctypes.get_errno()
print("same-HFS-native", "status", status, "errno", error, os.strerror(error), "destination_exists", os.path.exists(target))
target = os.path.join(base, "cp-samefs.txt")
status = subprocess.run(["/bin/cp", "-c", source, target]).returncode
print("same-HFS-cp-c", "status", status, "destination_exists", os.path.exists(target), "bytes_equal", subprocess.run(["cmp", "-s", source, target]).returncode == 0)
```

Exit 0:

```text
same-HFS-native status -1 errno 45 Operation not supported destination_exists False
same-HFS-cp-c status 0 destination_exists True bytes_equal True
```

The direct native call succeeded on the source filesystem, refused cross-device
operation (errno 18), and refused same-HFS operation (errno 45). On both HFS
copy controls, `cp -c` returned 0 and matching bytes despite native cloning
being unavailable. Thus a zero cp exit cannot establish clone-or-fail.

## Cleanup, limits and resulting requirement

Each attach was followed by successful
`hdiutil detach <the exact owned mount path>`, reporting disk4 ejected. The
16 MiB `unsupported.dmg` and empty mount directory were removed after final
detach. Only the tiny owned input and successful native-copy output remain.
No seed, cache, source, main ref, user stash or unrelated file was changed.

This proves the primitive distinction on this host, not complete tree walking,
safe-link handling, preflight/free-space accounting, source-race defense,
incremental Mix reuse, or actual Kogen admission. Implement and test those
through `Workspace`; use a native clone call that fails without byte-copy
fallback. The existing warm-seed requirement is unchanged; its mechanism is
corrected. A standalone shaping probe is not a current Build receipt.
