#!/usr/bin/env python3
import os
import pathlib
import signal
import time


pid_dir = pathlib.Path(os.environ["PID_DIR"])


def record(name: str, pid: int) -> None:
    (pid_dir / name).write_text(str(pid))


child_pid = os.fork()
if child_pid == 0:
    record("child", os.getpid())
    grandchild_pid = os.fork()
    if grandchild_pid == 0:
        record("grandchild", os.getpid())
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True:
            time.sleep(1)
    while True:
        time.sleep(1)

record("parent", os.getpid())
while True:
    time.sleep(1)
