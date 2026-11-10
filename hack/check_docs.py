#!/usr/bin/env python3
"""Check that the repository's relative documentation links resolve.

Checks every Git-tracked Markdown file for relative links whose target file
doesn't exist or whose #anchor doesn't match a heading in the target, and
every docs/*.md path mentioned in the chart's comments. External URLs aren't
checked.
"""

import os
from pathlib import Path
import re
import subprocess
import sys


LINK = re.compile(r"\]\(([^)\s]+)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
DOC_PATH = re.compile(r"\bdocs/[\w./-]+\.md\b")
CHART_FILES = ("charts/buildkite-operator/values.yaml", "charts/buildkite-operator/templates")


def slug(heading):
    """Return the anchor GitHub generates for a heading's text."""
    text = re.sub(r"<[^>]+>", "", heading)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def anchors(text):
    """Return every heading anchor in Markdown text, outside code blocks."""
    found = set()
    counts = {}
    fenced = False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        match = HEADING.match(line)
        if fenced or not match:
            continue
        base = slug(match.group(2))
        count = counts.get(base, 0)
        counts[base] = count + 1
        found.add(base if count == 0 else f"{base}-{count}")
    return found


def links(text):
    """Yield (line number, target) for each Markdown link outside code."""
    fenced = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        for match in LINK.finditer(re.sub(r"`[^`]*`", "", line)):
            yield number, match.group(1)


def check_markdown(root, path, cache):
    """Return problems with the relative links in one Markdown file."""
    problems = []
    text = (root / path).read_text(encoding="utf-8")
    for number, target in links(text):
        if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
            continue
        file_part, _, anchor = target.partition("#")
        resolved = (root / path).parent / file_part if file_part else root / path
        resolved = Path(os.path.normpath(resolved))
        if not resolved.exists():
            problems.append(f"{path}:{number}: {target}: {file_part} doesn't exist")
            continue
        if not anchor or resolved.suffix != ".md":
            continue
        if resolved not in cache:
            cache[resolved] = anchors(resolved.read_text(encoding="utf-8"))
        if anchor not in cache[resolved]:
            name = os.path.relpath(resolved, root)
            problems.append(f"{path}:{number}: {target}: no heading for #{anchor} in {name}")
    return problems


def check_doc_paths(root, path):
    """Return problems with docs/*.md paths mentioned in a non-Markdown file."""
    problems = []
    text = (root / path).read_text(encoding="utf-8")
    for number, line in enumerate(text.splitlines(), 1):
        for match in DOC_PATH.finditer(line):
            if not (root / match.group(0)).exists():
                problems.append(f"{path}:{number}: {match.group(0)} doesn't exist")
    return problems


def tracked(root, *pathspecs):
    output = subprocess.run(
        ["git", "ls-files", "-z", "--", *pathspecs],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout
    return sorted(path for path in output.split("\0") if path)


def main():
    root = Path(subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True,
    ).stdout.strip())
    cache = {}
    problems = []
    for path in tracked(root, "*.md"):
        problems += check_markdown(root, path, cache)
    for path in tracked(root, *CHART_FILES):
        problems += check_doc_paths(root, path)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print(f"{len(problems)} broken documentation link(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
