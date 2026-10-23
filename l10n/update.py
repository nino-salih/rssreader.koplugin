#!/usr/bin/env python3
"""Update the translation files of the plugin (rssreader_gettext.lua reads them).

    python l10n/update.py

1. Collect each _("...") text of the Lua files of the plugin (not spec/) into
   l10n/rssreader.pot, with the places that use it.
2. Merge the template into each l10n/<language>/rssreader.po. Existing
   translations stay, new texts come in empty, and the script removes texts
   that are no longer in use. English (the source language) gets the text
   itself as its translation.

To add a language, create l10n/<code>/rssreader.po with a header (copy one) and
run the script. Then fill in the empty msgstr entries.
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L10N = os.path.join(ROOT, "l10n")
POT = os.path.join(L10N, "rssreader.pot")

PLURAL_FORMS = {
    "de": "nplurals=2; plural=(n != 1);",
    "en": "nplurals=2; plural=(n != 1);",
    "es": "nplurals=2; plural=(n != 1);",
    "fr": "nplurals=2; plural=(n > 1);",
}

LANGUAGE_NAMES = {"de": "German", "en": "English", "es": "Spanish", "fr": "French"}

# One Lua string literal: "..." | '...' | [[...]] / [==[...]==]
LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'|\[(=*)\[.*?\]\1\]', re.S)
CALL_START = re.compile(r'(?<![\w.:])_\(')
SPACE = re.compile(r'\s*')
CONCAT = re.compile(r'\s*\.\.\s*')

LUA_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "a": "\a", "b": "\b",
               "f": "\f", "v": "\v", "\n": "\n"}


def lua_string(literal):
    """Return the value of one Lua string literal."""
    if literal.startswith("["):
        level = literal.index("[", 1) + 1
        body = literal[level:-level]
        return body[1:] if body.startswith("\n") else body
    body = literal[1:-1]
    out, i = [], 0
    while i < len(body):
        char = body[i]
        if char != "\\":
            out.append(char)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt in LUA_ESCAPES:
            out.append(LUA_ESCAPES[nxt])
            i += 2
        elif nxt == "u":
            end = body.index("}", i)
            out.append(chr(int(body[i + 3:end], 16)))
            i = end + 1
        elif nxt.isdigit():
            digits = re.match(r"\d{1,3}", body[i + 1:]).group(0)
            out.append(chr(int(digits)))
            i += 1 + len(digits)
        else:
            raise ValueError("unknown escape \\" + nxt)
    return "".join(out)


def lua_files():
    for path in sorted(glob.glob(os.path.join(ROOT, "**", "*.lua"), recursive=True)):
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        if not rel.startswith("spec/"):
            yield rel, path


def call_text(text, pos):
    """Return the text of _( literal [.. literal]* ) that starts after "_(" at pos, else None."""
    parts = []
    pos = SPACE.match(text, pos).end()
    while True:
        literal = LITERAL.match(text, pos)
        if not literal:
            return None
        parts.append(lua_string(literal.group(0)))
        pos = literal.end()
        concat = CONCAT.match(text, pos)
        if concat:
            pos = concat.end()
            continue
        pos = SPACE.match(text, pos).end()
        return "".join(parts) if text.startswith(")", pos) else None


def extract():
    """Return msgid -> list of "file:line", in the order of first use."""
    found = {}
    for rel, path in lua_files():
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for match in CALL_START.finditer(text):
            msgid = call_text(text, match.end())
            line = text.count("\n", 0, match.start()) + 1
            if msgid is None:
                # A string pattern such as "(_(%x+)" in Lua code is not a call.
                if LITERAL.match(text, SPACE.match(text, match.end()).end()):
                    print(f"warning: {rel}:{line}: _() with more than a text", file=sys.stderr)
                continue
            if msgid:
                found.setdefault(msgid, []).append(f"{rel}:{line}")
    return found


def po_quote(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\t", "\\t").replace("\r", "\\r")
    if "\n" not in escaped:
        return '"' + escaped + '"'
    lines = escaped.split("\n")
    parts = [line + "\\n" for line in lines[:-1]] + ([lines[-1]] if lines[-1] else [])
    return '""\n' + "\n".join('"' + part + '"' for part in parts)


def po_unquote(lines):
    text = "".join(re.match(r'^\s*(?:msg\w+(?:\[\d+\])?\s+)?"(.*)"\s*$', line).group(1) for line in lines)
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t", "r": "\r"}.get(m.group(1), m.group(1)), text)


def read_po(path):
    """Return msgid -> (msgstr, fuzzy) of an existing .po file."""
    entries = {}
    if not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8") as handle:
        blocks = handle.read().split("\n\n")
    for block in blocks:
        lines = [line for line in block.strip().split("\n") if line]
        fuzzy = any(line.startswith("#,") and "fuzzy" in line for line in lines)
        fields, current = {}, None
        for line in lines:
            if line.startswith("#"):
                continue
            key = re.match(r"^(msg\w+(?:\[\d+\])?)\s", line)
            if key:
                current = key.group(1)
                fields[current] = [line]
            elif current:
                fields[current].append(line)
        if "msgid" in fields and "msgstr" in fields:
            msgid = po_unquote(fields["msgid"])
            if msgid:
                entries[msgid] = (po_unquote(fields["msgstr"]), fuzzy)
    return entries


def header(language=None):
    lines = [
        "# Translations of the RSS Reader plugin for KOReader.",
        "# This file is distributed under the same license as the plugin (GPL-3.0).",
        "#",
        'msgid ""',
        'msgstr ""',
        '"Project-Id-Version: rssreader.koplugin\\n"',
        '"MIME-Version: 1.0\\n"',
        '"Content-Type: text/plain; charset=UTF-8\\n"',
        '"Content-Transfer-Encoding: 8bit\\n"',
    ]
    if language:
        lines[0] = f"# {LANGUAGE_NAMES.get(language, language)} translations of the RSS Reader plugin for KOReader."
        lines.append(f'"Language: {language}\\n"')
        lines.append(f'"Plural-Forms: {PLURAL_FORMS.get(language, "nplurals=2; plural=(n != 1);")}\\n"')
    return "\n".join(lines) + "\n"


def entry(msgid, refs, msgstr="", fuzzy=False):
    out = ["#: " + " ".join(refs[start:start + 3]) for start in range(0, len(refs), 3)]
    flags = (["c-format"] if "%" in msgid else []) + (["fuzzy"] if fuzzy else [])
    if flags:
        out.append("#, " + ", ".join(flags))
    out.append("msgid " + po_quote(msgid))
    out.append("msgstr " + po_quote(msgstr))
    return "\n".join(out) + "\n"


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def main():
    found = extract()
    write(POT, header() + "".join("\n" + entry(msgid, refs) for msgid, refs in found.items()))
    print(f"{len(found)} texts -> {os.path.relpath(POT, ROOT)}")
    for po_path in sorted(glob.glob(os.path.join(L10N, "*", "rssreader.po"))):
        language = os.path.basename(os.path.dirname(po_path))
        old = read_po(po_path)
        missing, body = 0, []
        for msgid, refs in found.items():
            msgstr, fuzzy = old.get(msgid, ("", False))
            if language == "en" and not msgstr:
                msgstr = msgid
            if not msgstr:
                missing += 1
            body.append("\n" + entry(msgid, refs, msgstr, fuzzy))
        write(po_path, header(language) + "".join(body))
        dropped = len(set(old) - set(found))
        print(f"{language}: {len(found) - missing} translated, {missing} missing, {dropped} dropped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
