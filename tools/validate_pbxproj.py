"""Structural validation for the hand-edited macOS project.pbxproj.

Xcode is not available on this machine, so the edit is verified by parsing the
file: OpenStep property lists use { } for dictionaries, ( ) for arrays, and
"..." for quoted strings (with backslash escapes). This script tokenizes the
file, checks that every group is closed and that the added build phase is
referenced exactly once.

Usage: python tools/validate_pbxproj.py macos/Runner.xcodeproj/project.pbxproj
"""

from __future__ import annotations

import sys


def parse(text: str) -> None:
    stack: list[tuple[str, int]] = []
    line = 1
    index = 0
    while index < len(text):
        char = text[index]
        if char == "\n":
            line += 1
            index += 1
            continue
        if char == '"':
            index += 1
            while index < len(text) and text[index] != '"':
                if text[index] == "\\":
                    index += 1
                if text[index] == "\n":
                    line += 1
                index += 1
            if index >= len(text):
                raise SystemExit(f"unterminated string starting near line {line}")
            index += 1
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index)
            if end == -1:
                raise SystemExit(f"unterminated comment near line {line}")
            line += text.count("\n", index, end)
            index = end + 2
            continue
        if char in "{(":
            stack.append((char, line))
            index += 1
            continue
        if char in ")}":
            if not stack:
                raise SystemExit(f"unexpected '{char}' at line {line}")
            opener, opened_at = stack.pop()
            if (opener, char) not in (("{", "}"), ("(", ")")):
                raise SystemExit(
                    f"mismatched '{opener}' at line {opened_at} closed by "
                    f"'{char}' at line {line}"
                )
            index += 1
            continue
        index += 1

    if stack:
        opener, opened_at = stack[-1]
        raise SystemExit(f"unclosed '{opener}' opened at line {opened_at}")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()

    parse(text)

    phase_id = "7D0C0DE00000000000000A01"
    references = text.count(phase_id)
    if references != 2:
        raise SystemExit(
            f"expected the Videoder Core phase id twice (definition + "
            f"buildPhases entry), found {references}"
        )
    for required in (
        "isa = PBXShellScriptBuildPhase;",
        "name = \"Build Videoder Core\";",
        "libvideoder_core.dylib",
        "cmake --build",
    ):
        if required not in text:
            raise SystemExit(f"missing expected content: {required}")

    print(
        f"ok: {path} parses, groups balanced, "
        f"{text.count(chr(10)) + 1} lines"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
