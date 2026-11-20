import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "local"))
from strategy_worker.contracts import Dispatch, Invalid
from strategy_worker.delivery import transition
from strategy_worker.models import candidates
from strategy_worker.process import git
from strategy_worker.store import Store
from strategy_worker.worker import Worker


def dispatch(**extra):
    return Dispatch.parse({
        "schema_version": 1, "run_id": "one-run", "attempt": 1, "kind": "code",
        "ticket": "MOZ-12", "project": "example", "goal": "Enable documented output",
        "done_check": "Observe the output from the entry point", "proof": "verification log",
        "known_info": "fixture", "constraints": "Keep the interface",
        "options": {"issue_type": "slice", "unresolved_dependencies": []}, **extra,
    })


class FakeForge:
    def __init__(self, tree, remote):
        self.tree, self.remote, self.pr = tree, remote, None
        self.merges = 0
        self.pending = False

    def find(self, branch, base):
        return self.view(self.pr["number"]) if self.pr else None

    def open(self, branch, base, title, body):
        self.pr = {"number": 1, "url": "https://example.invalid/pull/1",
                   "state": "OPEN", "headRefName": branch, "baseRefName": base}
        return self.view(1)

    def view(self, number):
        self.pr["headRefOid"] = git(self.remote, "rev-parse", f'refs/heads/{self.pr["headRefName"]}')
        return self.pr.copy()

    def ready(self, number, base):
        return not self.pending

    def merge(self, number, head):
        self.merges += 1
        other = self.tree.parent / "forge"
        git(self.tree.parent, "clone", str(self.remote), str(other))
        git(other, "merge", "--squash", head)
        git(other, "commit", "-m", "forge squash")
        git(other, "push", "origin", "HEAD:refs/heads/main")
        self.pr.update(state="MERGED", mergeCommit={"oid": git(other, "rev-parse", "HEAD")})


class WorkerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        directory = Path(self.temp.name)
        self.home = directory
        path = directory / "bin"
        path.mkdir()
        environment = {
            "PATH": f'{path}:{os.environ["PATH"]}', "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
        }
        scope = patch.dict(os.environ, environment)
        scope.start()
        self.addCleanup(scope.stop)
        fake = path / "pi"
        fake.write_text("""#!/bin/sh
set -eu
cat > /dev/null
git show HEAD:file >/dev/null
printf 'delivered\n' > file
git add file
git commit -qm change
""")
        fake.chmod(0o755)
        fake = path / "codex"
        fake.write_text("""#!/bin/sh
set -eu
cat > /dev/null
case " $* " in
  *' --sandbox read-only '*) printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"VERDICT: PASS"}}' ;;
  *) echo codex > file; git add file; git commit -qm implementation ;;
esac
""")
        fake.chmod(0o755)
        self.remote = directory / "bare"
        git(directory, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.repo = directory / "project"
        git(directory, "clone", str(self.remote), str(self.repo))
        (self.repo / "file").write_text("baseline\n")
        git(self.repo, "add", "file")
        git(self.repo, "commit", "-m", "baseline")
        git(self.repo, "push", "origin", "main")

        self.release = directory / "release"
        git(directory, "init", str(self.release))
        submodule = self.release / "ref/pstack"
        submodule.mkdir(parents=True)
        git(submodule, "init")
        entries = submodule / "skills/poteto-mode"
        (entries / "playbooks").mkdir(parents=True)
        for file in (entries / "SKILL.md", entries / "worker.md", entries / "playbooks/opening-a-pr.md"):
            file.write_text("immutable release entry\n")
        git(submodule, "add", ".")
        git(submodule, "commit", "-m", "pstack fixture")
        git(self.release, "update-index", "--add", "--cacheinfo",
            f'160000,{git(submodule, "rev-parse", "HEAD")},ref/pstack')
        git(self.release, "commit", "-m", "release")
        self.store = Store(directory / "jobs")
        self.config = {
            "projects": {"example": {"repo": str(self.repo), "base": "main",
                "github_repo": "example/project", "local_fixture_remote": True,
                "auto_merge": True, "verify_launcher": ["env"],
                "verify": ["sh", "-c", "test -s file && cat file"]}},
            "engines": {
                "pi": {"enabled": True, "implementation_launcher": ["env"],
                       "models": {"deepseek-v4.1-flash": {"cli_model": "deepseek", "vendor": "deepseek"}}},
                "codex": {"enabled": True, "implementation_launcher": ["env"], "review_launcher": ["env"],
                          "models": {"terra": {"cli_model": "terra"}}},
            },
        }
        self.config["engines"]["pi"]["environment"] = [
            "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"
        ]
        self.config["engines"]["codex"]["environment"] = self.config["engines"]["pi"]["environment"]
        self.forge = None

        def get_forge(name, tree):
            if self.forge is None:
                self.forge = FakeForge(tree, self.remote)
            return self.forge

        self.worker = Worker(self.store, self.config, self.release, forge=get_forge)

    def test_accept_replay_and_merge_through_pr(self):
        task = dispatch()
        job, created = self.worker.accept(task)
        self.assertTrue(created)
        self.assertEqual(self.worker.accept(task), (job, False))
        with self.assertRaises(Invalid):
            self.worker.accept(dispatch(goal="different"))
        state = self.worker.run(job)
        self.assertEqual(state["status"], "merged")
        self.assertNotEqual(state["head_sha"], state["merge_sha"])
        self.assertTrue(state["review"]["cross_vendor"])
        self.assertEqual(self.forge.merges, 1)
        self.assertEqual(self.worker.run(job), state)
        event = self.store.result(job)
        current = {"state": "In Progress", "run_id": "one-run", "attempt": 1, "ticket": "MOZ-12"}
        self.assertEqual(transition(event, current)["state"], "Done")
        current["last_event_id"] = event["event_id"]
        self.assertEqual(transition(event, current)["action"], "ignore")
        current.update(last_event_id="one-run:1:999")
        self.assertEqual(transition(event, current)["action"], "ignore")
        self.assertEqual(self.worker.gc(job, state, "2000-01-01T00:00:00Z", False)["status"], "eligible")
        self.assertEqual(self.worker.gc(job, state, "2000-01-01T00:00:00Z", True)["status"], "removed")
        self.assertTrue((job / "verification.log").is_file())

    def test_same_vendor_requires_sha_bound_waiver_and_independent_review(self):
        job, _ = self.worker.accept(dispatch(engine="codex", model="terra"))
        state = self.worker.run(job)
        self.assertEqual(state["status"], "awaiting_review")
        self.assertEqual(self.forge.merges, 0)
        self.store.update(job, "awaiting_review", waiver={
            "head_sha": "wrong", "pr_number": state["pr_number"], "approved_by": "test"})
        self.assertEqual(self.worker.run(job)["status"], "awaiting_review")
        self.store.update(job, "awaiting_review", waiver={
            "head_sha": state["head_sha"], "pr_number": state["pr_number"], "approved_by": "test"})
        state = self.worker.run(job)
        self.assertEqual(state["status"], "merged")
        self.assertFalse(state["review"]["cross_vendor"])

    def test_baseline_advance_blocks_approved_pr(self):
        project = self.config["projects"]["example"]
        project["auto_merge"] = False
        job, _ = self.worker.accept(dispatch())
        self.assertEqual(self.worker.run(job)["status"], "merge_wait")
        (self.repo / "other").write_text("base moved\n")
        git(self.repo, "add", "other")
        git(self.repo, "commit", "-m", "advance")
        git(self.repo, "push", "origin", "main")
        project["auto_merge"] = True
        state = self.worker.run(job)
        self.assertEqual(state["status"], "awaiting_review")
        self.assertIn("base changed", state["reason"])
        self.assertEqual(self.forge.merges, 0)

    def test_new_pr_head_invalidates_waiver(self):
        job, _ = self.worker.accept(dispatch(engine="codex", model="terra"))
        state = self.worker.run(job)
        self.store.update(job, "awaiting_review", waiver={
            "head_sha": state["head_sha"], "pr_number": state["pr_number"], "approved_by": "test"})
        branch = self.forge.pr["headRefName"]
        git(self.repo, "fetch", "origin", branch)
        git(self.repo, "switch", "-c", "external", "FETCH_HEAD")
        (self.repo / "file").write_text("external follow-up\n")
        git(self.repo, "commit", "-am", "follow-up")
        git(self.repo, "push", "origin", f"HEAD:refs/heads/{branch}")
        self.assertEqual(self.worker.run(job)["status"], "awaiting_review")
        head = git(self.repo, "rev-parse", "HEAD")
        refreshed = self.worker.refresh(job, self.store.state(job), head, "openai")
        self.assertIsNone(refreshed["waiver"])
        self.assertEqual(self.worker.run(job)["status"], "awaiting_review")
        self.assertEqual(self.forge.merges, 0)

    def test_pause_and_failure_budget(self):
        job, _ = self.worker.accept(dispatch())
        (job / "pause.request").touch()
        self.assertEqual(self.worker.run(job)["status"], "paused")
        (job / "pause.request").unlink()
        self.store.update(job, "accepted")
        launcher = self.config["engines"]["pi"]
        launcher["implementation_launcher"] = ["false"]
        self.assertEqual(self.worker.run(job)["status"], "retryable")
        next_job, _ = self.worker.accept(dispatch(attempt=2))
        self.assertEqual(self.worker.run(next_job)["status"], "blocked")
        with self.assertRaises(Invalid):
            self.worker.accept(dispatch(attempt=3))

    def test_reject_bad_contract_or_unlocked_state(self):
        with self.assertRaises(Invalid):
            dispatch(run_id="../../wrong")
        with self.assertRaises(Invalid):
            dispatch(attempt=True)
        with self.assertRaises(Invalid):
            self.worker.accept(dispatch(options={"issue_type": "spec", "unresolved_dependencies": []}))
        with self.assertRaises(Invalid):
            self.worker.accept(dispatch(options={"issue_type": "slice", "unresolved_dependencies": ["MOZ-1"]}))

    def test_model_order_and_vendor_filter(self):
        engines = self.config["engines"]
        engines["codex"]["models"]["sol"] = {"cli_model": "sol"}
        self.assertEqual([model.name for model in candidates(self.config, "review")], ["terra", "sol", "deepseek-v4.1-flash"])
        self.assertEqual([model.name for model in candidates(self.config, "review", exclude=("openai",))], ["deepseek-v4.1-flash"])
