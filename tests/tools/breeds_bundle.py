"""Extracts every breed's hit_zones / hitzone_armor_override / armor_type from the
DshProbe dump and emits a Lua bundle so the shipped armor.zone_for_actor and
armor.armor_type_for_actor can be executed against the real tables.

The rule being checked is the one the code documents: an actor can belong to more
than one zone (c_hips is under both torso and center_mass), a matched zone that
carries an armour override wins, and the first matched zone in the game's own
order is the fallback label.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lua_dump_parser import Parser, emit  # noqa: E402

SRC = r"mods\DshProbe\out\breeds.json"
OUT = r"mods\WeaponEffectiveness\tests\bundles\breeds_bundle.lua"

KEEP = ("armor_type", "hitzone_armor_override", "hitzone_damage_multiplier", "hit_zones",
        "hit_zone_weakspot_types", "display_name", "name")


def reduce_breed(body):
    out = {}
    for key in KEEP:
        if key in body:
            out[key] = body[key]

    # The dump is JSON-ish, so sequence tables (hit_zones) arrive as arrays.
    # Normalise them to Lua sequence tables with INTEGER keys -- string keys would
    # emit as ["1"] and leave #hit_zones at 0, which silently disables every
    # array-style iteration in the Lua under test.
    zones = out.get("hit_zones")
    if isinstance(zones, list):
        out["hit_zones"] = {i + 1: z for i, z in enumerate(zones)}
    return out


def _ordered_zone_keys(keys):
    """Numeric keys first, in numeric order, then the rest alphabetically."""
    def sort_key(key):
        text = str(key)
        return (0, int(text), "") if text.isdigit() else (1, 0, text)

    return sorted(keys, key=sort_key)


def _actor_names(actors):
    if isinstance(actors, dict):
        return [v for v in actors.values() if isinstance(v, str)]
    if isinstance(actors, list):
        return [v for v in actors if isinstance(v, str)]
    return []


def expectations(breed):
    """Independent statement of what each actor should resolve to.

    Mirrors the documented rule: the label is the matched zone carrying an
    override when there is one, otherwise the first matched zone in the game's
    order; the armour is that override, otherwise the breed-wide armour."""
    zones = breed.get("hit_zones")
    override = breed.get("hitzone_armor_override") or {}
    breed_armor = breed.get("armor_type")
    seen = {}

    if not isinstance(zones, dict):
        return {}

    ordered = [zones[k] for k in _ordered_zone_keys(zones.keys())
               if isinstance(zones[k], dict)]

    for zone in ordered:
        zone_name = zone.get("name")
        for actor in _actor_names(zone.get("actors")):
            entry = seen.setdefault(actor, {"first_zone": None, "override_zone": None})
            if entry["first_zone"] is None:
                entry["first_zone"] = zone_name
            if zone_name in override and entry["override_zone"] is None:
                entry["override_zone"] = zone_name

    out = {}
    for actor, entry in seen.items():
        override_zone = entry["override_zone"]
        out[actor] = {
            "zone": override_zone or entry["first_zone"],
            "armor": override[override_zone] if override_zone else breed_armor,
        }
    return out


def keyed_actors(breed):
    """Same breed but with each zone's actor set keyed by actor name, since the
    live game may hand it over either way."""
    zones = breed.get("hit_zones")
    if not isinstance(zones, dict):
        return breed

    converted = {}
    for index, zone in zones.items():
        if not isinstance(zone, dict):
            converted[index] = zone
            continue
        names = _actor_names(zone.get("actors"))
        if names:
            new_zone = dict(zone)
            # The other representation the game may use: a set keyed by name.
            new_zone["actors"] = {name: True for name in names}
            converted[index] = new_zone
        else:
            converted[index] = zone

    out = dict(breed)
    out["hit_zones"] = converted
    return out


def main():
    src = open(SRC, "r", encoding="utf-8", errors="replace").read()
    breeds_raw = Parser(src).value()
    print("breeds parsed:", len(breeds_raw))

    breeds = {name: reduce_breed(body) for name, body in breeds_raw.items() if isinstance(body, dict)}
    exp = {name: expectations(body) for name, body in breeds.items()}

    with_zones = sum(1 for b in breeds.values() if isinstance(b.get("hit_zones"), dict))
    with_override = sum(1 for b in breeds.values() if isinstance(b.get("hitzone_armor_override"), dict))
    total_actors = sum(len(e) for e in exp.values())
    multi_zone = 0
    for name, body in breeds.items():
        zones = body.get("hit_zones")
        if not isinstance(zones, dict):
            continue
        seen = {}
        for zone in zones.values():
            if isinstance(zone, dict):
                for actor in _actor_names(zone.get("actors")):
                    seen[actor] = seen.get(actor, 0) + 1
        multi_zone += sum(1 for v in seen.values() if v > 1)

    print("breeds with hit_zones        :", with_zones)
    print("breeds with armour override  :", with_override)
    print("distinct actor slots         :", total_actors)
    print("actors listed under >1 zone  :", multi_zone)

    bundle = {
        "breeds": breeds,
        "breeds_keyed": {name: keyed_actors(body) for name, body in breeds.items()},
        "expected": exp,
    }

    out = []
    emit(bundle, out)
    text = "return " + "".join(out) + "\n"
    with open(OUT, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("wrote", OUT, len(text), "chars")


if __name__ == "__main__":
    main()
