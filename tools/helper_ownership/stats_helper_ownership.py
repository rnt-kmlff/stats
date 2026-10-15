"""Opt-in, event-driven association export for a cooperating macOS helper.

Call observe_chat() with the normalized UUID from request metadata, never prompts
or tool arguments. All exports are SHARED associations, including one-chat exports.
No background service, heartbeat, process control, network or argument reads.
"""
import atexit
import ctypes
import itertools
import json
import os
import pathlib
import stat
import sys
import threading
import time
import uuid

MAX_CHATS = 8
MAX_FILES = 128
MAX_BYTES = 8192


class _BSDInfo(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint32) for n in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid",
        "rgid", "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(n, ctypes.c_uint32) for n in ("nfiles", "pgid", "pjobc", "tdev", "tpgid")]
    _fields_ += [("nice", ctypes.c_int32), ("start", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]


def process_identity(pid):
    if sys.platform != "darwin":
        raise OSError("This prototype supports macOS only")
    if pid not in (os.getpid(), os.getppid()):
        raise OSError("Only the publisher or its direct parent may export")
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.restype = ctypes.c_int
    info = _BSDInfo()
    size = ctypes.sizeof(info)
    if size != 136 or lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size:
        raise OSError("Process birth identity unavailable")
    if info.pid != pid or info.uid != os.getuid() or not info.start or info.microseconds >= 1_000_000:
        raise OSError("Invalid process identity")
    return dict(pid=info.pid, uid=info.uid, startSeconds=info.start, startMicroseconds=info.microseconds)


def _private_directory(parent, name):
    try:
        os.mkdir(name, 0o700, dir_fd=parent)
    except FileExistsError:
        pass
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    details = os.fstat(fd)
    if details.st_uid != os.getuid() or stat.S_IMODE(details.st_mode) != 0o700:
        os.close(fd)
        raise OSError("Export directory must be owned by this user with mode 0700")
    return fd


class HelperOwnershipExporter:
    """One instance per helper process. A failed export must not fail a tool call."""
    def __init__(self, application_support=None, _parent=False, _instance=None):
        self.identity = process_identity(os.getppid() if _parent else os.getpid())
        self._writer_pid = os.getpid()
        self.base = pathlib.Path(application_support) if application_support else pathlib.Path.home() / "Library/Application Support"
        self.instance = _instance or str(uuid.uuid4())
        self.chats = []
        self.overflow = False
        self._fd = None
        self._lock = threading.Lock()
        self._closed = False
        self._published = False
        self._dirty = False
        self.filename = "{pid}-{startSeconds}-{startMicroseconds}.json".format(**self.identity)
        if not _parent:
            atexit.register(self.close)

    def _directory(self):
        if self._fd is not None:
            return self._fd
        parent = os.open(self.base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            root = _private_directory(parent, "Stats Helper Ownership")
        finally:
            os.close(parent)
        try:
            self._fd = _private_directory(root, "v1")
        finally:
            os.close(root)
        return self._fd

    def observe_chat(self, chat_id):
        try:
            if not isinstance(chat_id, str) or len(chat_id) != 36:
                return False
            normalized = str(uuid.UUID(chat_id))
            if normalized != chat_id.lower():
                return False
            with self._lock:
                if self._closed or os.getpid() != self._writer_pid:
                    return False
                changed = False
                if normalized not in self.chats:
                    if len(self.chats) < MAX_CHATS:
                        self.chats.append(normalized)
                        changed = True
                    elif not self.overflow:
                        self.overflow = True
                        changed = True
                self._dirty = self._dirty or changed
                if not self._dirty and self._published:
                    return True
                fd = self._directory()
                # Bounded advisory capacity check. Concurrent publishers can race;
                # the reader's independent per-scan limits remain authoritative.
                with os.scandir(fd) as entries:
                    count = sum(1 for _ in itertools.islice(entries, MAX_FILES + 1))
                if not self._published and count >= MAX_FILES:
                    return False
                payload = dict(version=1, instanceId=self.instance, sharing="shared", chatIds=sorted(self.chats),
                               overflow=self.overflow, writtenAt=time.time(), **self.identity)
                data = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
                if len(data) > MAX_BYTES:
                    return False
                temporary = "." + self.instance + ".tmp"
                output = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)
                try:
                    with os.fdopen(output, "wb") as stream:
                        stream.write(data)
                    os.replace(temporary, self.filename, src_dir_fd=fd, dst_dir_fd=fd)
                    self._published = True
                    self._dirty = False
                finally:
                    try:
                        os.unlink(temporary, dir_fd=fd)
                    except FileNotFoundError:
                        pass
                return True
        except (OSError, ValueError, TypeError):
            return False

    def close(self):
        with self._lock:
            if self._closed or os.getpid() != self._writer_pid:
                return
            self._closed = True
            if self._fd is not None:
                try:
                    # Remove only this publisher's exact private, regular record.
                    fd = os.open(self.filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self._fd)
                    try:
                        details = os.fstat(fd)
                        if (details.st_uid == os.getuid() and stat.S_ISREG(details.st_mode) and details.st_nlink == 1
                                and stat.S_IMODE(details.st_mode) == 0o600 and details.st_size <= MAX_BYTES):
                            data = os.read(fd, MAX_BYTES + 1)
                            if json.loads(data).get("instanceId") == self.instance:
                                os.unlink(self.filename, dir_fd=self._fd)
                    finally:
                        os.close(fd)
                except (OSError, ValueError, TypeError):
                    pass
                os.close(self._fd)
                self._fd = None


def _parent_main():
    # Node adapter sends only bounded normalized UUIDs. The parent PID and birth
    # are read from the kernel here, never accepted from request payloads.
    try:
        raw = sys.stdin.buffer.read(2049)
        if len(raw) > 2048:
            raise ValueError("Oversized metadata")
        data = json.loads(raw)
        if set(data) != {"instanceId", "chatIds", "overflow", "close"}:
            raise ValueError("Unexpected metadata")
        if not isinstance(data["instanceId"], str) or len(data["instanceId"]) != 36:
            raise ValueError("Invalid publisher ID")
        instance = str(uuid.UUID(data["instanceId"]))
        ids = data["chatIds"]
        if not isinstance(ids, list) or not 1 <= len(ids) <= MAX_CHATS or len(set(ids)) != len(ids):
            raise ValueError("Invalid chat list")
        if any(not isinstance(x, str) or str(uuid.UUID(x)) != x for x in ids):
            raise ValueError("Invalid UUID")
        if type(data["overflow"]) is not bool or type(data["close"]) is not bool:
            raise ValueError("Invalid flags")
        exporter = HelperOwnershipExporter(sys.argv[2] if len(sys.argv) == 3 else None, _parent=True, _instance=instance)
        fd = exporter._directory()
        try:
            handle = os.open(exporter.filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            try:
                details = os.fstat(handle)
                if (stat.S_ISREG(details.st_mode) and details.st_uid == os.getuid() and details.st_nlink == 1
                        and stat.S_IMODE(details.st_mode) == 0o600 and details.st_size <= MAX_BYTES):
                    previous = json.loads(os.read(handle, MAX_BYTES + 1))
                    exporter._published = previous.get("instanceId") == instance
            finally:
                os.close(handle)
        except (OSError, ValueError, TypeError):
            pass
        if data["close"]:
            exporter.close()
            result = True
        else:
            exporter.chats = ids[:-1]
            exporter.overflow = data["overflow"]
            exporter._dirty = True
            result = exporter.observe_chat(ids[-1])
        print(json.dumps({"ok": result, "identity": exporter.identity}))
    except (OSError, ValueError, TypeError, KeyError):
        print('{"ok":false}')


if __name__ == "__main__" and sys.argv[1:2] == ["--parent-export"]:
    _parent_main()
