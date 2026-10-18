#!/usr/bin/env python3
"""Reject phone-number-like text added to a commit or its message."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


E164_PATTERN = re.compile(r"(?<!\w)\+\d(?:[ ().-]*\d){7,14}(?!\w)")
NANP_PATTERN = re.compile(
    r"(?<!\w)(?:1[ .-]?)?(?:\([2-9]\d{2}\)|[2-9]\d{2})"
    r"[ .-]?[2-9]\d{2}[ .-]?\d{4}(?!\w)"
)


def is_reserved_example_number(value: str) -> bool:
    digits = re.sub(r"\D", "", value)
    if len(digits) == 11 and digits.startswith("1"):
        national_number = digits[1:]
    elif len(digits) == 10:
        national_number = digits
    else:
        return False

    # NANPA reserves 555-0100 through 555-0199 as fictitious numbers.
    return national_number[3:6] == "555" and national_number[6:8] == "01"


def phone_format(line: str) -> str | None:
    e164_match = E164_PATTERN.search(line)
    if e164_match and not is_reserved_example_number(e164_match.group()):
        return "E.164-style number"

    nanp_match = NANP_PATTERN.search(line)
    if nanp_match and not is_reserved_example_number(nanp_match.group()):
        return "North American number"
    return None


def staged_additions() -> list[tuple[str, int, str]]:
    result = subprocess.run(
        ["git", "diff", "--cached", "--no-ext-diff", "--no-color", "--unified=0", "--"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    findings: list[tuple[str, int, str]] = []
    path = "<unknown>"
    new_line_number: int | None = None
    hunk_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")

    for line in result.stdout.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
            new_line_number = None
            continue
        hunk = hunk_re.match(line)
        if hunk:
            new_line_number = int(hunk.group(1))
            continue
        if new_line_number is None:
            continue
        if line.startswith("+"):
            content = line[1:]
            kind = phone_format(content)
            if kind:
                findings.append((path, new_line_number, kind))
            new_line_number += 1
        elif line.startswith(" "):
            new_line_number += 1

    return findings


def message_additions(path: Path) -> list[tuple[int, str]]:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        print(f"phone guard: cannot read commit message: {error}", file=sys.stderr)
        raise SystemExit(2)
    return [
        (line_number, kind)
        for line_number, line in enumerate(lines, start=1)
        if (kind := phone_format(line))
    ]


def report(findings: list[tuple[str, int, str]]) -> int:
    if not findings:
        return 0
    print("phone guard: commit blocked; phone-number-like text found:", file=sys.stderr)
    for path, line_number, kind in findings:
        print(f"  {path}:{line_number} ({kind}; value hidden)", file=sys.stderr)
    print("Remove or redact the number before committing.", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--staged", action="store_true")
    source.add_argument("--message", type=Path)
    args = parser.parse_args()

    if args.staged:
        return report(staged_additions())

    findings = [
        (str(args.message), line_number, kind)
        for line_number, kind in message_additions(args.message)
    ]
    return report(findings)


if __name__ == "__main__":
    raise SystemExit(main())
