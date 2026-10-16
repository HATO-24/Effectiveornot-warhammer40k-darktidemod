"""Measures how many talent-granted buffs can be given the game's own name offline.

The question this answers: the buff rows only show buffs they can NAME (an internal
id on the HUD is worse than a missing line), so how many can we actually name?

The oracle is `LocalizationExport`'s LocalizationKeys.lua -- 154k key names with no
text, which is exactly what is needed here: the runtime localiser supplies the text,
and the naming RULE is what has to be got right.

A buff template declares `related_talents`. Those ids are not always the talent's own
id: some carry a qualifier for one component of a talent (`adamant_execution_order_cdr`
is the cooldown part of `adamant_execution_order`). So the lookup walks the id down,
segment by segment, and also tries the `_name` form.

Run from the game root:
    python mods\\WeaponEffectiveness\\tests\\tools\\talent_name_coverage.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lua_dump_parser import Parser  # noqa: E402

MODS = r"mods"
KEY_FILE = os.path.join(
    MODS, "LocalizationExport", "scripts", "mods", "LocalizationExport", "LocalizationKeys.lua"
)
BUFF_DUMP = os.path.join(MODS, "DshProbe", "out", "buff_templates.json")

# Segments that qualify a talent rather than name it. Stripped one at a time, from
# the right, so `..._execution_order_cdr_max` still finds `..._execution_order`.
QUALIFIERS = {
    "cdr", "crit", "rending", "permastack", "stack", "stacks", "max", "min",
    "buff", "node", "low", "medium", "high", "1", "2", "3", "4", "5", "effect",
    "dot", "debuff", "toughness", "damage",
}


def load_keys(path):
    keys = set()

    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            key = line.strip()

            if key and not key.startswith(("--", "return", "local", "{")):
                keys.add(key)

    return keys


def load_talent_ids(path):
    parsed = Parser(open(path, encoding="utf-8", errors="replace").read()).value()
    data = parsed.get("__data") if isinstance(parsed, dict) and "__data" in parsed else parsed
    ids = set()

    for _, body in data.items():
        if not isinstance(body, dict):
            continue

        related = body.get("related_talents")

        if isinstance(related, dict):
            related = list(related.values())

        if isinstance(related, list):
            ids |= {item for item in related if isinstance(item, str)}

    return ids


def candidates(talent_id):
    """Every key worth trying for this id, best first."""
    yield "loc_talent_" + talent_id
    yield "loc_talent_" + talent_id + "_name"

    parts = talent_id.split("_")

    # Walk the id down one segment at a time, but only past segments that look like
    # qualifiers -- otherwise `ogryn_melee_attacks_give_mtdr` would be cut into
    # nonsense that happens to collide with some other key.
    while len(parts) > 2 and parts[-1] in QUALIFIERS:
        parts = parts[:-1]
        trimmed = "_".join(parts)
        yield "loc_talent_" + trimmed
        yield "loc_talent_" + trimmed + "_name"


def main():
    keys = load_keys(KEY_FILE)
    ids = load_talent_ids(BUFF_DUMP)

    named, by_rule, missing = {}, {}, []

    for talent_id in sorted(ids):
        for candidate in candidates(talent_id):
            if candidate in keys:
                named[talent_id] = candidate
                by_rule[candidate.split("_name")[0].replace("loc_talent_", "") != talent_id and "via parent" or "direct"] = \
                    by_rule.get(candidate.split("_name")[0].replace("loc_talent_", "") != talent_id and "via parent" or "direct", 0) + 1
                break
        else:
            missing.append(talent_id)

    total = len(ids)
    print("key inventory      : %d keys" % len(keys))
    print("talent ids         : %d" % total)
    print("nameable           : %d (%.0f%%)" % (len(named), 100.0 * len(named) / max(1, total)))
    print("  direct id        : %d" % by_rule.get("direct", 0))
    print("  via parent / _name: %d" % by_rule.get("via parent", 0))
    print("not nameable       : %d" % len(missing))
    print("  sample           : %s" % ", ".join(missing[:8]))


if __name__ == "__main__":
    main()
