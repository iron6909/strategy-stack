"""Retryable webhook wakeups and the Linear transition frontier."""

import json
import re
import urllib.error
from urllib.parse import urlsplit
import urllib.request

from .contracts import Invalid


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def post(url, token, result):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.fragment:
        raise Invalid("webhook endpoint must be an HTTPS URL")
    if not token or any(char in token for char in "\r\n"):
        raise Invalid("invalid webhook credential")
    request = urllib.request.Request(
        url, data=json.dumps(result, ensure_ascii=False).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + token},
        method="POST",
    )
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=8) as response:
            if 200 <= response.status < 300:
                return response.status
    except (OSError, urllib.error.URLError) as error:
        raise Invalid("callback wakeup failed; result is still available for replay") from error
    raise Invalid("callback wakeup was not accepted")


def transition(event, snapshot):
    """Return the next transition using a current Linear snapshot, without external writes."""
    if any(event.get(key) != snapshot.get(key) for key in ("ticket", "run_id", "attempt")):
        return {"action": "ignore", "reason": "stale attempt"}
    prefix = f'{event["run_id"]}:{event["attempt"]}:'
    event_id = event["event_id"]
    if not isinstance(event_id, str) or not event_id.startswith(prefix) or not event_id[len(prefix):].isdigit():
        raise Invalid("invalid event_id")
    previous = snapshot.get("last_event_id") or ""
    if not isinstance(previous, str):
        raise Invalid("invalid last_event_id")
    if snapshot.get("state") == "Done" or (
        previous.startswith(prefix) and previous[len(prefix):].isdigit()
        and int(previous[len(prefix):]) >= int(event_id[len(prefix):])
    ):
        return {"action": "ignore", "reason": "already applied"}
    status = event["status"]
    if status == "merged":
        if event.get("kind") != "code" or not all(
            event.get(field) for field in ("pr_url", "pr_number", "merge_sha", "head_sha")
        ):
            raise Invalid("merged result requires the actual PR and merge receipt")
        target = "Done"
    elif status == "produced":
        if event.get("kind") != "production" or not all(
            event.get("output", {}).get(field) for field in ("artifact", "verification", "archive")
        ):
            raise Invalid("production result requires verified output and archive")
        target = "Done"
    elif status == "blocked":
        target = "Blocked"
    elif status == "retryable":
        return {"action": "retry", "event_id": event["event_id"], "reason": event.get("reason")}
    else:
        return {"action": "wait", "event_id": event["event_id"]}
    return {"action": "transition", "state": target, "event_id": event["event_id"],
            "unlock_after_readback": target == "Done"}


def validate_draft(text, measured):
    limit = 35 if measured else 12
    banned = ("赋能", "抓手", "底层逻辑", "闭环", "赛道", "感谢分享", "让我们一起来看看", "—")
    if not 1 <= len(text) <= limit or text != text.strip() or len(text.splitlines()) != 1:
        raise Invalid(f"draft must contain 1–{limit} characters on one line")
    if any(word in text for word in banned) or re.search(r"不仅.*更是", text):
        raise Invalid("draft contains a prohibited phrase or dash")
    return {"characters": len(text), "valid": True}
