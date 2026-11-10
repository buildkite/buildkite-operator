import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "check_docs", Path(__file__).resolve().parent / "check_docs.py",
)
check_docs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_docs)


class SlugTest(unittest.TestCase):
    def test_matches_github_anchors(self):
        for heading, expected in (
            ("Runner pools", "runner-pools"),
            ("What's reset between jobs", "whats-reset-between-jobs"),
            ("`dind`, `kata` and `sysbox`", "dind-kata-and-sysbox"),
            ("OCI Accelerator CA", "oci-accelerator-ca"),
            ("Step images and bind mounts", "step-images-and-bind-mounts"),
        ):
            with self.subTest(heading=heading):
                self.assertEqual(check_docs.slug(heading), expected)

    def test_numbers_duplicates_and_ignores_code_blocks(self):
        text = "# Peering\n\n```yaml\n# off.yaml\n```\n\n## Peering\n"
        self.assertEqual(check_docs.anchors(text), {"peering", "peering-1"})


class CheckMarkdownTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        (self.root / "docs").mkdir()
        (self.root / "docs/appendices.md").write_text("# Appendices\n\n## Setup\n")

    def tearDown(self):
        self.directory.cleanup()

    def check(self, text):
        (self.root / "README.md").write_text(text)
        return check_docs.check_markdown(self.root, "README.md", {})

    def test_accepts_resolving_links(self):
        self.assertEqual(self.check(
            "# Title\n\n## Install\n\n"
            "[a](#install) [b](docs/appendices.md#setup) [c](docs/appendices.md) "
            "[d](https://example.com/#missing)\n"
        ), [])

    def test_reports_missing_files_and_anchors(self):
        problems = self.check(
            "# Title\n\n[a](#missing) [b](docs/missing.md) [c](docs/appendices.md#nope)\n"
        )
        self.assertEqual(len(problems), 3)
        self.assertIn("no heading for #missing in README.md", problems[0])
        self.assertIn("docs/missing.md doesn't exist", problems[1])
        self.assertIn("no heading for #nope in docs/appendices.md", problems[2])

    def test_ignores_links_in_code(self):
        self.assertEqual(self.check(
            "# Title\n\n`[a](#missing)`\n\n```md\n[b](#missing)\n```\n"
        ), [])

    def test_checks_doc_paths_in_chart_comments(self):
        (self.root / "values.yaml").write_text(
            "# See docs/appendices.md.\n# See docs/missing.md.\n"
        )
        problems = check_docs.check_doc_paths(self.root, "values.yaml")
        self.assertEqual(problems, ["values.yaml:2: docs/missing.md doesn't exist"])


if __name__ == "__main__":
    unittest.main()
