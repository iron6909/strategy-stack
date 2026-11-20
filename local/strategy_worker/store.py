"""Durable per-attempt job records, advisory leases, and delivery acknowledgements."""

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import tempfile

from .contracts import Invalid, compact, identifier, read_object


def atomic_json(path, value):
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".write-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(compact(value) + "\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
        fd_dir = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(fd_dir)
        finally:
            os.close(fd_dir)
    finally:
        Path(name).unlink(missing_ok=True)


@contextmanager
def lease(path, blocking=False):
    fd = os.open(path, os.O_CREAT | os.O_NOFOLLOW | os.O_RDWR | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield
    finally:
        os.close(fd)


class Store:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)

    def accept(self, dispatch):
        body = dispatch.body
        run = self.root / identifier(body["run_id"], "run_id")
        run.mkdir(mode=0o700, exist_ok=True)
        job = run / str(body["attempt"])
        with lease(run / ".accept.lock", blocking=True):
            job.mkdir(mode=0o700, exist_ok=True)
            path = job / "dispatch.json"
            siblings = sorted((p for p in run.iterdir() if p.name.isdecimal()), key=lambda p: int(p.name))
            prior = [p for p in siblings if p != job and (p / "dispatch.json").exists()]
            if path.exists():
                if read_object(path) != body:
                    raise Invalid("dispatch replay does not match accepted input")
                return job, False
            if prior:
                latest = prior[-1]
                previous = read_object(latest / "dispatch.json")
                if body["attempt"] != previous["attempt"] + 1 or any(
                    body[key] != previous[key] for key in ("ticket", "kind", "project")
                ):
                    raise Invalid("attempt must follow the same run, ticket and project")
                state = self.state(latest)
                authorization = state.get("retry_authorization") or {}
                hypothesis = body.get("options", {}).get("hypothesis_id")
                if state["status"] != "retryable" and not (
                    state["status"] == "blocked" and hypothesis
                    and authorization.get("hypothesis_id") == hypothesis
                ):
                    raise Invalid(f'previous attempt is {state["status"]}')
            elif body["attempt"] != 1:
                raise Invalid("first attempt must be 1")
            atomic_json(path, body)
            return job, True

    def job(self, run_id, attempt):
        if not 1 <= attempt <= 100000:
            raise Invalid("invalid attempt")
        job = self.root / identifier(run_id, "run_id") / str(attempt)
        if not (job / "dispatch.json").is_file():
            raise Invalid("unknown job")
        return job

    def state(self, job):
        path = job / "state.json"
        return read_object(path) if path.exists() else {"status": "accepted", "revision": 0}

    def update(self, job, status, **details):
        old = self.state(job)
        state = {**old, **details, "status": status}
        if state == old:
            return old
        state["revision"] += 1
        atomic_json(job / "state.json", state)
        return state

    def result(self, job):
        body = read_object(job / "dispatch.json")
        values = self.state(job)
        event = {key: body[key] for key in ("schema_version", "run_id", "attempt", "ticket", "kind", "project")}
        return {**event, "event_id": f'{event["run_id"]}:{event["attempt"]}:{values["revision"]}', **values}
