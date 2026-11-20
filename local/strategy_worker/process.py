"""Process adapters for Git, local agents and the GitHub PR surface."""

from dataclasses import asdict
import json
import os
from pathlib import Path
import re
import subprocess

from .contracts import Invalid, arguments, object_json


class Failed(RuntimeError):
    pass


class Unavailable(Failed):
    pass


def command(argv, cwd, *, timeout=90, accepted=(0,)):
    environment = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1", "GH_PROMPT_DISABLED": "1"}
    reply = subprocess.run(argv, cwd=cwd, text=True, capture_output=True, timeout=timeout, env=environment)
    if reply.returncode not in accepted:
        raise Failed(f"{Path(argv[0]).name} exited {reply.returncode}")
    return reply


def git(cwd, *args, **kwargs):
    return command(["git", "-c", "core.hooksPath=/dev/null", *args], cwd, **kwargs).stdout.strip()


def launch(argv, cwd, prompt, log, *, launcher, timeout, env=None, keep=()):
    argv = [*arguments(launcher, "isolated launcher"), *argv]
    allowed = {"PATH", "HOME", "LANG", "LC_ALL", "TZ", "DISPLAY", "WAYLAND_DISPLAY",
               "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "XAUTHORITY",
               "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"}
    forbidden = {"GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
                 "GH_CONFIG_DIR", "SSH_AUTH_SOCK", "STRATEGY_WEBHOOK_TOKEN"}
    if not isinstance(keep, (tuple, list)) or not all(isinstance(key, str) and key not in forbidden for key in keep):
        raise Invalid("invalid child environment allowlist")
    environment = {key: os.environ[key] for key in allowed.union(keep) if key in os.environ}
    environment.update(env or {})
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        reply = subprocess.run(argv, cwd=cwd, input=prompt, text=True,
                               stdout=output, stderr=subprocess.STDOUT,
                               timeout=timeout, env=environment)
    return reply.returncode


def run_agent(config, model, cwd, prompt, log, *, review=False):
    settings = config["engines"][model.engine]
    launcher = settings.get("review_launcher" if review else "implementation_launcher")
    if not launcher:
        raise Unavailable(f"{model.engine} has no configured launcher for this role")
    if model.engine == "codex":
        argv = ["codex", "exec", "--model", model.cli_model, "--sandbox",
                "read-only" if review else "workspace-write",
                "--ephemeral", "--color", "never", "--json", "-"]
    elif model.engine == "agy":
        argv = ["agy", "--model", model.cli_model, "--sandbox", "--input-format", "text"]
        if review:
            argv += ["--disable-slash-commands", "--mode", "plan"]
    else:
        argv = ["pi", "--model", model.cli_model, "--print", "--mode", "text", "--no-session"]
        if review:
            argv += ["--no-tools", "--no-mcp", "--no-extensions", "--no-skills", "--no-context-files"]
    code = launch(argv, cwd, prompt, log, launcher=launcher, timeout=900 if review else 5400,
                  keep=settings.get("environment", ()))
    if code in settings.get("unavailable_exit_codes", [126, 127]):
        raise Unavailable(f"{model.engine}/{model.name} unavailable (exit {code})")
    if code:
        raise Failed(f"{model.engine}/{model.name} exited {code}")
    if not review:
        return asdict(model), ""
    text = log.read_text(encoding="utf-8", errors="replace")
    if model.engine == "codex":
        messages = []
        for line in text.splitlines():
            try:
                event = object_json(line)
            except (json.JSONDecodeError, Invalid):
                continue
            item = event.get("item") or {}
            if event.get("type") == "item.completed" and item.get("type") == "agent_message":
                messages.append(item.get("text", ""))
        text = messages[-1] if messages else ""
    return asdict(model), text


class GitHub:
    def __init__(self, name, cwd):
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", name):
            raise Invalid("github_repo must be OWNER/REPO")
        self.name, self.cwd = name, cwd

    def run(self, *args, accepted=(0,)):
        return command(["gh", *args, "--repo", self.name], self.cwd, accepted=accepted)

    def find(self, branch, base):
        listing = self.run("pr", "list", "--state", "all", "--head", branch, "--base", base,
                           "--json", "number,isCrossRepository").stdout
        matches = [entry["number"] for entry in json.loads(listing) if not entry["isCrossRepository"]]
        if len(matches) > 1:
            raise Failed("multiple PRs for the dispatch branch")
        return self.view(matches[0]) if matches else None

    def view(self, number):
        fields = "number,url,state,headRefOid,headRefName,baseRefName,isCrossRepository,mergeCommit"
        info = object_json(self.run("pr", "view", str(number), "--json", fields).stdout)
        if info["isCrossRepository"]:
            raise Failed("unexpected fork PR")
        return info

    def open(self, branch, base, title, body):
        existing = self.find(branch, base)
        if existing:
            return existing
        self.run("pr", "create", "--head", branch, "--base", base,
                 "--title", title, "--body-file", str(body))
        result = self.find(branch, base)
        if not result:
            raise Failed("created PR is not visible yet")
        return result

    def ready(self, number, base):
        from urllib.parse import quote

        # Require a server-side up-to-date check to close the base-moves-during-merge gap.
        rules = object_json(command(
            ["gh", "api", f"repos/{self.name}/branches/{quote(base, safe='')}/protection/required_status_checks"],
            self.cwd,
        ).stdout)
        if rules.get("strict") is not True or not (rules.get("checks") or rules.get("contexts")):
            raise Failed("target branch needs strict required status checks")
        checks = self.run("pr", "checks", str(number), "--required", accepted=(0, 8))
        return checks.returncode == 0

    def merge(self, number, head):
        self.run("pr", "merge", str(number), "--squash", "--match-head-commit", head)
