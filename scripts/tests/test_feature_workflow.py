"""Regression tests for feature integration and release tooling."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("changelog", SCRIPTS / "changelog.py")
changelog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelog)


class GitFixture(unittest.TestCase):
    def setUp(self):
        """Create an isolated repository with main, nightly, and a local bare remote.

        Raises:
            OSError: A temporary file or Git process cannot be created.
            subprocess.CalledProcessError: Repository initialization fails.
        """
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.remote = self.root / "origin.git"
        self.repo.mkdir()
        self.run_command("git", "init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "rerere.enabled", "false")
        self.commit("base", "base")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "origin", "main")
        self.git("switch", "-c", "nightly")
        self.git("push", "origin", "nightly")

    def run_command(self, *args, check=True):
        """Run a command in the fixture repository with isolated Git configuration.

        Args:
            *args: Executable and its command-line arguments.
            check: Whether a nonzero exit status raises an exception.

        Raises:
            OSError: The process cannot be started.
            subprocess.CalledProcessError: The command fails while check is True.

        Returns:
            CompletedProcess with text stdout and stderr combined in stdout.
        """
        env = os.environ.copy()
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(args, cwd=self.repo, env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=check)

    def git(self, *args):
        """Run Git in the fixture repository.

        Args:
            *args: Git subcommand and its arguments.

        Raises:
            OSError: Git cannot be started.
            subprocess.CalledProcessError: Git exits with a nonzero status.

        Returns:
            Combined command output with surrounding whitespace removed.
        """
        return self.run_command("git", *args).stdout.strip()

    def commit(self, name, content):
        """Write and commit one fixture file.

        Args:
            name: Relative file path, also used as the commit subject.
            content: Text to write to the file.

        Raises:
            OSError: The file cannot be written or Git cannot start.
            subprocess.CalledProcessError: Staging, committing, or revision lookup fails.

        Returns:
            Full commit ID of the new HEAD.
        """
        (self.repo / name).write_text(content)
        self.git("add", name)
        self.git("commit", "-m", name)
        return self.git("rev-parse", "HEAD")

    def feature(self, name="feature"):
        """Create a feature branch and merge it into nightly on the remote.

        Args:
            name: Feature branch name and the file used for its initial change.

        Raises:
            OSError: A fixture file cannot be written or Git cannot start.
            subprocess.CalledProcessError: Branch creation, merging, or pushing fails.

        Returns:
            Full commit ID of the initial feature tip.
        """
        self.git("switch", "-c", name, "main")
        tip = self.commit(name, "first")
        self.git("push", "origin", name)
        self.git("switch", "nightly")
        self.git("merge", "--no-ff", "-m", f"Merge branch '{name}' into nightly", name)
        self.git("push", "origin", "nightly")
        return tip

    def rebuild(self, *args, check=True):
        """Run the nightly rebuild script in the fixture repository.

        Args:
            *args: Rebuild script arguments.
            check: Whether a nonzero exit status raises an exception.

        Raises:
            OSError: Bash cannot be started.
            subprocess.CalledProcessError: The rebuild fails while check is True.

        Returns:
            CompletedProcess with the rebuild output and exit status.
        """
        return self.run_command("bash", str(SCRIPTS / "rebuild_nightly.sh"), *args, check=check)

    def test_empty_nightly_rebuild(self):
        """Verify rebuilding nightly with no active features preserves main.

        Raises:
            AssertionError: The workflow violates the expected behavior.
            OSError: Fixture files or processes cannot be accessed.
            subprocess.CalledProcessError: A fixture Git command or expected rebuild fails.
        """
        self.rebuild()
        self.assertEqual(self.git("rev-parse", "HEAD"), self.git("rev-parse", "main"))

    def test_advanced_feature_is_retained(self):
        """Verify an integrated branch retains commits pushed after its nightly merge.

        Raises:
            AssertionError: The workflow violates the expected behavior.
            OSError: Fixture files or processes cannot be accessed.
            subprocess.CalledProcessError: A fixture Git command or expected rebuild fails.
        """
        self.feature()
        self.git("switch", "feature")
        tip = self.commit("feature", "second")
        self.git("push", "origin", "feature")
        self.rebuild()
        self.git("merge-base", "--is-ancestor", tip, "HEAD")

    def test_rewritten_feature_is_retained(self):
        """Verify a rewritten branch is retained by its recorded merge identity.

        Raises:
            AssertionError: The workflow violates the expected behavior.
            OSError: Fixture files or processes cannot be accessed.
            subprocess.CalledProcessError: A fixture Git command or expected rebuild fails.
        """
        self.feature()
        self.git("switch", "feature")
        self.git("reset", "--soft", "main")
        self.git("commit", "-m", "rewritten feature")
        tip = self.git("rev-parse", "HEAD")
        self.git("push", "--force", "origin", "feature")
        self.rebuild()
        self.git("merge-base", "--is-ancestor", tip, "HEAD")

    def test_unmerged_branch_is_not_collected_after_main_sync(self):
        """Verify merging main into nightly does not select an unrelated branch.

        Raises:
            AssertionError: The workflow violates the expected behavior.
            OSError: Fixture files or processes cannot be accessed.
            subprocess.CalledProcessError: A fixture Git command or expected rebuild fails.
        """
        self.feature()
        self.git("switch", "-c", "unmerged", "main")
        tip = self.commit("unmerged", "not integrated")
        self.git("push", "origin", "unmerged")
        self.git("switch", "main")
        self.commit("main-update", "new main")
        self.git("push", "origin", "main")
        self.git("switch", "nightly")
        self.git("merge", "--no-ff", "main")
        self.git("push", "origin", "nightly")
        self.rebuild()
        result = self.run_command("git", "merge-base", "--is-ancestor", tip, "HEAD", check=False)
        self.assertEqual(result.returncode, 1)

    def test_unmerged_stacked_branch_requires_explicit_add(self):
        """Verify an unmerged stacked branch enters a rebuild only with --add.

        Raises:
            AssertionError: The workflow violates the expected behavior.
            OSError: Fixture files or processes cannot be accessed.
            subprocess.CalledProcessError: A fixture Git command or expected rebuild fails.
        """
        self.feature()
        self.git("switch", "-c", "unmerged", "feature")
        tip = self.commit("unmerged", "not integrated")
        self.git("push", "origin", "unmerged")
        self.rebuild()
        result = self.run_command("git", "merge-base", "--is-ancestor", tip, "HEAD", check=False)
        self.assertEqual(result.returncode, 1)
        self.git("merge-base", "--is-ancestor", "feature", "HEAD")
        self.rebuild("--add", "unmerged")
        self.git("merge-base", "--is-ancestor", tip, "HEAD")

    def test_github_merge_matches_full_branch_name(self):
        """Verify GitHub merge subjects retain only the complete source branch name.

        Raises:
            AssertionError: A branch with a matching suffix is collected.
            OSError: Fixture files or processes cannot be accessed.
            subprocess.CalledProcessError: A fixture command or rebuild fails.
        """
        self.git("switch", "-c", "group/feature", "main")
        self.commit("integrated", "first")
        self.git("push", "origin", "group/feature")
        self.git("switch", "nightly")
        self.git("merge", "--no-ff", "-m", "Merge pull request #42 from larecs/group/feature", "group/feature")
        self.git("push", "origin", "nightly")
        self.git("switch", "group/feature")
        self.git("reset", "--soft", "main")
        self.git("commit", "-m", "rewritten feature")
        tip = self.git("rev-parse", "HEAD")
        self.git("push", "--force", "origin", "group/feature")
        self.git("switch", "-c", "feature", "main")
        unmerged = self.commit("unmerged", "not integrated")
        self.git("push", "origin", "feature")
        self.rebuild()
        self.git("merge-base", "--is-ancestor", tip, "HEAD")
        result = self.run_command("git", "merge-base", "--is-ancestor", unmerged, "HEAD", check=False)
        self.assertEqual(result.returncode, 1)

    def test_aborted_merge_is_retried_on_continue(self):
        """Verify --continue retries an aborted merge and accepts its later resolution.

        Raises:
            AssertionError: The workflow violates the expected behavior.
            OSError: Fixture files or processes cannot be accessed.
            subprocess.CalledProcessError: A fixture Git command or expected rebuild fails.
        """
        self.feature()
        self.git("switch", "main")
        self.commit("feature", "conflicting main change")
        self.git("push", "origin", "main")
        self.assertNotEqual(self.rebuild(check=False).returncode, 0)
        self.git("merge", "--abort")
        self.assertNotEqual(self.rebuild("--continue", check=False).returncode, 0)
        self.assertEqual(self.git("rev-parse", "MERGE_HEAD"), self.git("rev-parse", "origin/feature"))
        (self.repo / "feature").write_text("resolved")
        self.git("add", "feature")
        self.git("commit", "--no-edit")
        self.rebuild("--continue")
        self.git("merge-base", "--is-ancestor", "origin/feature", "HEAD")

    def test_archive_rejects_old_nightly_contamination(self):
        """Verify archived nightly commits are rejected while clean features remain valid.

        Raises:
            AssertionError: The workflow violates the expected behavior.
            OSError: Fixture files or processes cannot be accessed.
            subprocess.CalledProcessError: A fixture Git command or expected rebuild fails.
        """
        self.feature()
        old = self.git("rev-parse", "nightly")
        self.git("switch", "-c", "contaminated", "feature")
        self.git("merge", "--no-ff", "-m", "accidental nightly merge", "nightly")
        self.rebuild("--push")
        self.assertEqual(self.git("ls-remote", "origin", f"refs/heads/nightly-history/{old}").split()[0], old)
        self.git("fetch", "origin")
        self.git("switch", "contaminated")
        result = self.run_command("bash", str(SCRIPTS / "check_feature_branch.sh"), check=False)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.git("switch", "feature")
        self.run_command("bash", str(SCRIPTS / "check_feature_branch.sh"))
        self.rebuild()
        self.assertNotIn("+ nightly-history/", self.rebuild().stdout)

    def test_changelog_changed_path_validation(self):
        """Verify changelog checks reject nested and non-Markdown fragments.

        Raises:
            AssertionError: The workflow violates the expected behavior.
            OSError: Fixture files or processes cannot be accessed.
            subprocess.CalledProcessError: A fixture Git command or expected rebuild fails.
        """
        base = self.git("rev-parse", "HEAD")
        original_run = subprocess.run
        for name in ("feature.txt", "sub/feature.md", "sub/README.md"):
            path = self.repo / "changelog.d" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("### Fixed\n\n- An entry.\n")
            self.git("add", str(path))
            self.git("commit", "-m", "invalid fragment path")
            with patch.object(changelog.subprocess, "run", side_effect=lambda *a, **kw: original_run(*a, cwd=self.repo, **kw)):
                with self.assertRaisesRegex(SystemExit, "top-level"):
                    changelog.changed_fragments(base)
            self.git("reset", "--hard", base)

    def test_changelog_accepts_spaces_and_ignores_readme(self):
        """Verify fragment checks and collection agree on spaces and the README exclusion.

        Raises:
            AssertionError: The workflow violates the expected behavior.
            OSError: Fixture files or processes cannot be accessed.
            subprocess.CalledProcessError: A fixture Git command or expected rebuild fails.
        """
        base = self.git("rev-parse", "HEAD")
        fragment = self.repo / "changelog.d" / "feature with spaces.md"
        fragment.parent.mkdir()
        fragment.write_text("### Fixed\n\n- An entry.\n")
        (fragment.parent / "README.md").write_text("Instructions")
        self.git("add", "changelog.d")
        self.git("commit", "-m", "valid fragment")
        original_run = subprocess.run
        with patch.object(changelog.subprocess, "run", side_effect=lambda *a, **kw: original_run(*a, cwd=self.repo, **kw)):
            self.assertEqual(changelog.changed_fragments(base), [Path("changelog.d/feature with spaces.md")])
        with patch.object(changelog, "FRAGMENTS", fragment.parent):
            self.assertEqual(changelog.fragment_paths(), [fragment])


if __name__ == "__main__":
    unittest.main()
