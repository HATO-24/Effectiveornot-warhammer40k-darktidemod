"""Extracts BuffStackHUD's curated buff -> localisation-key table.

BuffStackHUD (already installed) solved the problem this project was stuck on: it
names active buffs. Its localisation file pairs a setting/group id with a
`Localize("loc_talent_...")` key -- a hand-checked mapping, including `_name`
variants that cannot be derived mechanically from a talent id.

This pulls that mapping out and checks it against the 154k-key inventory, so the mod
can use it as another naming source instead of guessing at id rules.

Run from the game root:
    python mods\\WeaponEffectiveness\\tests\\tools\\buffstackhud_map.py
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lua_dump_parser import Parser  # noqa: E402

MODS = r"mods"
SOURCE = os.path.join(MODS, "BuffStackHUD", "scripts", "mods", "BuffStackHUD", "BuffStackHUD_localization.lua")
DATA = os.path.join(MODS, "BuffStackHUD", "scripts", "mods", "BuffStackHUD", "BuffStackHUD_data.lua")
KEYS = os.path.join(MODS, "LocalizationExport", "scripts", "mods", "LocalizationExport", "LocalizationKeys.lua")
BUFF_DUMP = os.path.join(MODS, "DshProbe", "out", "buff_templates.json")
OUT = os.path.join(MODS, "WeaponEffectiveness", "out", "buffstackhud_map.json")

# The file is Lua source with Localize() calls, not a data dump, so it is read by
# shape: an `id = {` opens an entry, and the first Localize("loc_talent_...") inside
# it is that entry's talent key.
ENTRY = re.compile(r"^\s*([A-Za-z0-9_]+)\s*=\s*\{")
LOC_CALL = re.compile(r'Localize\(\s*"(loc_talent_[A-Za-z0-9_]+)"')


def extract(path):
    mapping = {}
    current = None

    for line in open(path, encoding="utf-8", errors="replace"):
        opened = ENTRY.match(line)

        if opened:
            current = opened.group(1)

        found = LOC_CALL.search(line)

        if found and current:
            mapping.setdefault(current, found.group(1))

    return mapping


def load_keys(path):
    keys = set()

    for line in open(path, encoding="utf-8", errors="replace"):
        key = line.strip()

        if key and not key.startswith(("--", "return", "local", "{")):
            keys.add(key)

    return keys


def main():
    mapping = extract(SOURCE)
    keys = load_keys(KEYS)

    parsed = Parser(open(BUFF_DUMP, encoding="utf-8", errors="replace").read()).value()
    data = parsed.get("__data") if isinstance(parsed, dict) and "__data" in parsed else parsed
    buffs = {name for name in data if isinstance(name, str)}

    in_inventory = {name: key for name, key in mapping.items() if key in keys}
    matched_buffs = {name: key for name, key in mapping.items() if name in buffs}

    os.makedirs(os.path.dirname(OUT), exist_ok=True)

    with open(OUT, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "all": mapping,
                "keys_present_in_inventory": in_inventory,
                "matching_a_buff_template": matched_buffs,
            },
            handle,
            ensure_ascii=False,
            indent=1,
        )

    print("entries in BuffStackHUD's table      : %d" % len(mapping))
    print("their loc keys exist in the inventory: %d" % len(in_inventory))
    print("entries whose id IS a buff template  : %d" % len(matched_buffs))
    print("buff templates in the game           : %d" % len(buffs))
    print("wrote %s" % OUT)

    sample = list(matched_buffs.items())[:5]

    for name, key in sample:
        print("   %-44s -> %s" % (name, key))


if __name__ == "__main__":
    main()
