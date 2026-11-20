"""Read release and project policy, then manage an isolated implementation checkout."""

import hashlib
from pathlib import Path
import re

from .contracts import Invalid, arguments, read_object, relative_path
from .process import Failed, git
from .store import atomic_json


def release_entry(root):
    expected = git(root, "rev-parse", "HEAD:ref/pstack")
    directory = root / "ref" / "pstack"
    if not (directory / ".git").exists() or git(directory, "rev-parse", "HEAD") != expected:
        raise Failed("initialize the pstack submodule at the release gitlink")
    if git(directory, "--no-optional-locks", "status", "--porcelain", "--untracked-files=all"):
        raise Failed("the pstack release checkout must be clean")
    entry = directory / "skills" / "poteto-mode" / "SKILL.md"
    for file in (entry, entry.parent / "worker.md", entry.parent / "playbooks" / "opening-a-pr.md"):
        if not file.is_file():
            raise Failed("pstack release is missing a required entry")
    return entry, expected


def project_config(config, dispatch):
    value = config.get("projects", {}).get(dispatch["project"])
    if not isinstance(value, dict):
        raise Invalid("project is not registered")
    source = Path(value["repo"]).resolve(strict=True)
    if git(source, "rev-parse", "--show-toplevel") != str(source):
        raise Invalid("registered repo must be a repository root")
    if dispatch["kind"] == "code":
        base = value["base"]
        if not isinstance(base, str) or base.startswith("-"):
            raise Invalid("invalid base branch")
        git(source, "check-ref-format", f"refs/heads/{base}")
        arguments(value.get("verify"), "project verify")
        arguments(value.get("verify_launcher"), "project verify_launcher")
        if value.get("policy_path"):
            relative_path(value["policy_path"], "policy_path")
        remote = git(source, "remote", "get-url", "origin")
        expected = value["github_repo"]
        github = re.fullmatch(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+?)(?:\.git)?", remote)
        if (not github or github[1].casefold() != expected.casefold()) and not (
            value.get("local_fixture_remote") is True and Path(remote).is_absolute()
        ):
            raise Invalid("registered GitHub repository does not match origin")
    else:
        arguments(value.get("production"), "project production")
        arguments(value.get("production_launcher"), "project production_launcher")
    return value, source


def checkout(repo, base, branch, job):
    mirror = job / "clone"
    tree = job / "worktree"
    if not mirror.exists():
        remote = git(repo, "remote", "get-url", "origin")
        git(job, "clone", "--no-local", "--no-checkout", "--", remote, str(mirror), timeout=300)
    if not tree.exists():
        git(mirror, "fetch", "origin", base)
        previous = git(mirror, "ls-remote", "--heads", "origin", f"refs/heads/{branch}")
        start = f"refs/remotes/origin/{base}"
        if previous:
            git(mirror, "fetch", "origin", f"refs/heads/{branch}")
            start = "FETCH_HEAD"
        git(mirror, "worktree", "add", "-b", branch, str(tree), start)
        atomic_json(job / "git-boundary.json", git_boundary(job))
    assert_git_boundary(job)
    if git(tree, "symbolic-ref", "--short", "HEAD") != branch:
        raise Failed("worktree branch differs from dispatch")
    return tree


def git_boundary(job):
    relative = ("clone/.git/config", "worktree/.git", "clone/.git/worktrees/worktree/commondir",
                "clone/.git/worktrees/worktree/gitdir")
    fingerprints = {}
    for name in relative:
        path = job / name
        if path.is_symlink() or path.resolve() != path.absolute() or not path.is_file():
            raise Failed("unexpected Git boundary path")
        fingerprints[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    if any((job / name).exists() for name in (
        "clone/.git/config.worktree", "clone/.git/worktrees/worktree/config.worktree",
    )):
        raise Failed("unexpected per-worktree Git configuration")
    return fingerprints


def assert_git_boundary(job):
    if read_object(job / "git-boundary.json") != git_boundary(job):
        raise Failed("implementation changed the trusted Git configuration")


def assert_tip(tree, base, head, policy, *, mirror):
    paths = (".task", ".pi", "out", "projects")
    for commit in git(tree, "rev-list", f"{base}..{head}").splitlines():
        if git(tree, "ls-tree", "-r", "--name-only", commit, "--", *paths):
            raise Failed("runtime artifacts are present in candidate history")
    if git(tree, "status", "--porcelain", "--untracked-files=all"):
        raise Failed("implementation has uncommitted tracked changes")
    if not policy:
        return
    path = relative_path(policy["required_file"], "required_file")
    if not git(tree, "ls-tree", head, "--", str(path)).startswith(("100644 blob ", "100755 blob ")):
        raise Failed("required instruction file is missing from candidate")
    upstream = policy["baseline"]
    if not isinstance(upstream, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", upstream):
        raise Invalid("policy baseline must be a pinned commit")
    git(mirror, "merge-base", base, upstream)
    prefixes = [relative_path(item, "allowed_prefix").as_posix() + "/" for item in policy["allow"]]
    for source in (base, upstream):
        result = git(tree, "diff", "-z", "--no-renames", "--name-only", source, head)
        if any(not any(name.startswith(prefix) for prefix in prefixes) for name in result.split("\x00") if name):
            raise Failed("candidate changes paths outside the project policy")


def proof(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise Failed("nonempty verification evidence required")
    with path.open("rb") as file:
        return {"name": path.name, "sha256": hashlib.file_digest(file, "sha256").hexdigest()}
