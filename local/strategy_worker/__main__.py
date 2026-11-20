"""Command entry for the trusted local dispatcher."""

import argparse
import os
from pathlib import Path
import pwd
import subprocess
import sys

from .contracts import Dispatch, Invalid, compact, read_object
from .delivery import post, transition, validate_draft
from .process import Failed
from .store import Store, atomic_json, lease
from .worker import Worker


def parse():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path.home() / ".harness" / "strategy-worker.json")
    commands = parser.add_subparsers(dest="command", required=True)
    accept = commands.add_parser("accept")
    accept.add_argument("dispatch", type=Path)
    next_transition = commands.add_parser("transition")
    next_transition.add_argument("event", type=Path)
    next_transition.add_argument("snapshot", type=Path)
    draft = commands.add_parser("draft-check")
    draft.add_argument("text")
    draft.add_argument("--measured", action="store_true")
    for label in ("run", "status", "deliver", "ack", "pause", "resume", "waive", "refresh", "gc", "authorize-retry"):
        sub = commands.add_parser(label)
        sub.add_argument("run_id")
        sub.add_argument("attempt", type=int)
        if label == "ack":
            sub.add_argument("event_id")
        if label == "waive":
            sub.add_argument("head")
            sub.add_argument("--reason", required=True)
        if label == "refresh":
            sub.add_argument("head")
            sub.add_argument("--vendor", required=True)
        if label == "authorize-retry":
            sub.add_argument("hypothesis_id")
        if label == "gc":
            sub.add_argument("--linear-done-at", required=True)
            sub.add_argument("--apply", action="store_true")
    return parser.parse_args()


def execute(args):
    if args.command == "transition":
        return transition(read_object(args.event), read_object(args.snapshot))
    if args.command == "draft-check":
        return validate_draft(args.text, args.measured)
    config = read_object(args.config)
    root = Path(__file__).resolve().parents[2]
    store = Store(config["state_dir"])
    worker = Worker(store, config, root)
    if args.command == "accept":
        job, created = worker.accept(Dispatch.parse(read_object(args.dispatch)))
        return {**store.result(job), "created": created}
    job = store.job(args.run_id, args.attempt)
    if args.command == "run":
        worker.run(job)
    elif args.command == "deliver":
        event = store.result(job)
        ack = job / "ack.json"
        if ack.is_file() and read_object(ack)["event_id"] == event["event_id"]:
            return {**event, "delivery": "acknowledged"}
        status = post(config["webhook_url"], os.environ.get("STRATEGY_WEBHOOK_TOKEN", ""), event)
        return {**event, "delivery": "wake_accepted", "http_status": status}
    elif args.command == "pause":
        atomic_json(job / "pause.request", {"requested": True})
    elif args.command != "status":
        with lease(job / ".work.lock"):
            state = store.state(job)
            if args.command == "ack":
                event = store.result(job)
                if args.event_id != event["event_id"]:
                    raise Invalid("acknowledgement does not match the current receipt")
                atomic_json(job / "ack.json", {"event_id": args.event_id})
            elif args.command == "resume":
                if state["status"] != "paused":
                    raise Invalid("job is not paused")
                next_status = state["resume_status"]
                if state.get("implementation_in_flight"):
                    from .process import git

                    if git(job / "worktree", "rev-parse", "HEAD") != state["base_sha"] or git(
                        job / "worktree", "status", "--porcelain", "-uall"
                    ):
                        raise Invalid("interrupted implementation has changes; preserve them and refresh explicitly")
                if state.get("production_actor") and next_status == "accepted" and not (
                    job / "production-output" / "result.json"
                ).is_file():
                    raise Invalid("reconcile the project receipt before restarting production")
                (job / "pause.request").unlink(missing_ok=True)
                store.update(job, next_status, reason=None)
            elif args.command in ("waive", "refresh", "gc", "authorize-retry"):
                operator = pwd.getpwuid(os.getuid()).pw_name
                if operator not in config.get("operators", []):
                    raise Invalid("operation requires a configured human operator account")
                if args.command == "waive":
                    if state["status"] not in ("pr_open", "awaiting_review") or state.get("head_sha") != args.head:
                        raise Invalid("waiver requires the current PR head")
                    if not args.reason.strip() or len(args.reason) > 1000:
                        raise Invalid("a short waiver reason is required")
                    store.update(job, state["status"], waiver={
                        "pr_number": state["pr_number"], "head_sha": args.head,
                        "approved_by": operator, "reason": args.reason,
                    })
                elif args.command == "refresh":
                    worker.refresh(job, state, args.head, args.vendor)
                elif args.command == "authorize-retry":
                    from .contracts import identifier

                    hypothesis = identifier(args.hypothesis_id, "hypothesis_id")
                    if state["status"] != "blocked" or hypothesis == state.get("hypothesis_id"):
                        raise Invalid("a blocked job needs a new, explicit hypothesis")
                    store.update(job, "blocked", retry_authorization={
                        "hypothesis_id": hypothesis, "approved_by": operator,
                    })
                else:
                    return worker.gc(job, state, args.linear_done_at, args.apply)
    return store.result(job)


def main():
    try:
        print(compact(execute(parse())))
    except BlockingIOError:
        print("job is already running", file=sys.stderr)
        return 3
    except (Invalid, Failed, KeyError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
