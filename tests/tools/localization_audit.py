"""Reconciles every localisation source in the mod folder into one report.

Why a tool instead of reading the files: the sources add up to ~9 MB, and the thing
that actually matters is not the text but the DISAGREEMENTS -- one key carrying two
different strings for the same language, which is how a mod silently overrides
another. This walks all of them, merges, and writes:

    out/localization_audit.json   every key, with which source said what
    out/localization_audit.md     the summary and the conflicts, worst first

Run from the game root:
    python mods\\WeaponEffectiveness\\tests\\tools\\localization_audit.py
"""
import json
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lua_dump_parser import Parser  # noqa: E402

MODS = r"mods"
OUT_DIR = os.path.join(MODS, "WeaponEffectiveness", "out")

# The mods that carry localisation text. Matched by folder name so the audit is
# reproducible rather than "whatever happened to be in the folder".
SOURCE_PATTERN = re.compile(r"locali[sz]|localisation|localization", re.I)

# Locales the game ships. A key's value table is recognised by these.
LOCALES = {
    "en", "zh-cn", "zh-tw", "ja", "ko", "ru", "pl", "es", "de", "fr",
    "pt-br", "it",
}

SKIP_DIRS = {".git", "out", "node_modules"}


def source_files():
    found = []
    for entry in sorted(os.listdir(MODS)):
        folder = os.path.join(MODS, entry)
        if not os.path.isdir(folder) or not SOURCE_PATTERN.search(entry):
            continue
        for root, dirs, files in os.walk(folder):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in files:
                if name.endswith((".lua", ".json")):
                    found.append(os.path.join(root, name))
    return found


def parse_file(path):
    """Returns the file's table, or None. Both Lua-ish dumps and plain JSON."""
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None

    for loader in ("lua", "json"):
        try:
            if loader == "lua":
                return Parser(text).value()
            return json.loads(text)
        except Exception:
            continue

    return None


def collect(value, key_prefix, out, source):
    """Walks a parsed file and records every key -> {locale: text} it can find.

    Two shapes occur in the wild: a flat table of key -> locale table, and a nested
    one (a wrapper per language, or per namespace). Both are handled by looking for
    any table whose values are strings in locale positions.
    """
    if not isinstance(value, dict):
        return

    for key, body in value.items():
        if not isinstance(key, str) or not isinstance(body, dict):
            # A wrapper table: descend, keeping the wrapper name as a prefix.
            if isinstance(body, dict):
                collect(body, key_prefix, out, source)
            continue

        locales = {k: v for k, v in body.items() if isinstance(k, str) and k.lower() in LOCALES and isinstance(v, str)}

        if locales:
            full_key = key_prefix + key if key_prefix else key
            record = out.setdefault(full_key, {})
            bucket = record.setdefault(source, {})
            for locale, text in locales.items():
                bucket[locale.lower()] = text
        else:
            # Not a locale table: treat as a namespace and descend.
            collect(body, key_prefix + key + ".", out, source)


def main():
    files = source_files()
    merged = {}

    for path in files:
        parsed = parse_file(path)
        if parsed is None:
            print("  unparsed: %s" % path)
            continue

        source = os.path.relpath(path, MODS).split(os.sep)[0]
        collect(parsed, "", merged, source)

    per_source = Counter()
    conflicts = defaultdict(dict)

    for key, sources in merged.items():
        for source in sources:
            per_source[source] += 1

        for locale in LOCALES:
            seen = {}

            for source, texts in sources.items():
                text = texts.get(locale)

                if text is None:
                    continue

                norm = " ".join(text.split())

                if norm:
                    seen.setdefault(norm, []).append(source)

            if len(seen) > 1:
                conflicts[key][locale] = {text: srcs for text, srcs in seen.items()}

    os.makedirs(OUT_DIR, exist_ok=True)

    with open(os.path.join(OUT_DIR, "localization_audit.json"), "w", encoding="utf-8") as handle:
        json.dump({"merged": merged, "conflicts": conflicts}, handle, ensure_ascii=False, indent=1)

    ranked = sorted(conflicts.items(), key=lambda item: -len(item[1]))

    with open(os.path.join(OUT_DIR, "localization_audit.md"), "w", encoding="utf-8") as handle:
        handle.write("# Localisation audit\n\n")
        handle.write("%d files, %d keys\n\n" % (len(files), len(merged)))
        handle.write("## Keys contributed per source\n\n")
        for source, count in per_source.most_common():
            handle.write("- %s: %d\n" % (source, count))
        handle.write("\n## Conflicts (%d keys)\n\n" % len(conflicts))
        for key, locales in ranked[:200]:
            handle.write("### %s\n\n" % key)
            for locale, variants in sorted(locales.items()):
                for text, srcs in variants.items():
                    handle.write("- `%s` <- %s: %s\n" % (locale, ", ".join(sorted(srcs)), text[:200]))
            handle.write("\n")

    print("files        : %d" % len(files))
    print("keys         : %d" % len(merged))
    print("conflicts    : %d" % len(conflicts))
    print("per source   : %s" % ", ".join("%s=%d" % (s, c) for s, c in per_source.most_common()))
    print("wrote        : %s" % os.path.join(OUT_DIR, "localization_audit.md"))


if __name__ == "__main__":
    main()
