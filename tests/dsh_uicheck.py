"""Consolidated UI checks for the WeaponEffectiveness mod.

Covers, in one place, every UI-level invariant that has actually broken or nearly
broken during development:

  1. every localisation key the UI asks for exists
  2. only vanilla loc_* keys are passed to the game's Localize -- mod strings must
     go through mod:localize, or they render as "unlocalized"
  3. the HUD element really does use mod.localize
  4. the row count in the HUD element, its definitions and its row budget agree
  5. DMF runs localisation values through string.format, so a literal percent must
     be written %% (a bare one throws at load and the option renders empty)
  6. every option tooltip / group / dropdown label has a localisation entry
"""
import os
import re
import sys

# Repo layout: this file lives in <repo>/tests/, the mod scripts live under
# <repo>/scripts/mods/WeaponEffectiveness.
BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts', 'mods', 'WeaponEffectiveness')

FILES = {
    "loc": os.path.join(BASE, "WeaponEffectiveness_localization.lua"),
    "data": os.path.join(BASE, "WeaponEffectiveness_data.lua"),
    "main": os.path.join(BASE, "WeaponEffectiveness.lua"),
    "hud": os.path.join(BASE, "hud", "hud_element_weapon_effectiveness.lua"),
    "defs": os.path.join(BASE, "hud", "hud_element_weapon_effectiveness_definitions.lua"),
    "profiles": os.path.join(BASE, "modules", "weapon_profiles.lua"),
    "armor": os.path.join(BASE, "modules", "armor.lua"),
}

text = {name: open(path, encoding="utf-8").read() for name, path in FILES.items()}

problems = []
loc_keys = set(re.findall(r'^\t([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{', text["loc"], re.M))

# --- 1. every key the UI can ask for ------------------------------------------
wanted = set()

# verdict labels, from the HUD's verdict table
verdict_block = re.search(r"VERDICT_LOC\s*=\s*\{(.*?)\n\}", text["hud"], re.S)
if verdict_block:
    wanted |= set(re.findall(r'"([a-z_]+)"', verdict_block.group(1)))
else:
    problems.append("could not find VERDICT_LOC in the HUD element")

wanted.add("special_active_marker")

# attack labels: melee kinds are built as "attack_" .. kind in the main script,
# and the HUD maps each row to a label through ATTACK_LOC.
attack_kinds = re.search(r"ATTACK_KINDS\s*=\s*\{([^}]*)\}", text["main"])
if attack_kinds:
    for kind in re.findall(r'"([a-z]+)"', attack_kinds.group(1)):
        wanted.add("attack_" + kind)
else:
    problems.append("could not find ATTACK_KINDS in the main script")

attack_loc = re.search(r"ATTACK_LOC\s*=\s*\{(.*?)\n\}", text["hud"], re.S)
if attack_loc:
    wanted |= set(re.findall(r'"([a-z_]+)"', attack_loc.group(1)))
else:
    problems.append("could not find ATTACK_LOC in the HUD element")

label_block = re.search(r"LABEL_PATTERNS\s*=\s*\{(.*?)\n\}", text["profiles"], re.S)
if label_block:
    wanted |= set(re.findall(r'label\s*=\s*"([a-z_]+)"', label_block.group(1)))
else:
    problems.append("could not find LABEL_PATTERNS in weapon_profiles")

for key in sorted(wanted):
    if key not in loc_keys:
        problems.append("UI wants localisation key %r but it is not defined" % key)

# Body-part annotations: every zone the best-zone pivot can name needs a label.
zone_order = re.search(r"ZONE_ORDER\s*=\s*\{(.*?)\n\}", text["armor"], re.S)
if zone_order:
    for zone in re.findall(r'"([a-z_]+)"', zone_order.group(1)):
        if ("zone_" + zone) not in loc_keys:
            problems.append("zone %r is in ZONE_ORDER but has no zone_%s label" % (zone, zone))
else:
    problems.append("could not find ZONE_ORDER in armor.lua")

# Plus every zone_* key the scripts reference by name (the whole-body fallback and
# anything added later must not render as a raw key).
for name in ("main", "hud"):
    for key in re.findall(r'"(zone_[a-z_]+)"', text[name]):
        if key not in loc_keys:
            problems.append("%s references %r but it is not defined" % (name, key))

# --- 2/3. the right lookup API -------------------------------------------------
if "mod.localize" not in text["hud"]:
    problems.append("HUD element never calls mod.localize: mod keys would render as unlocalized")

for name in ("hud", "armor"):
    for match in re.finditer(r'\bLocalize\s*\(\s*"([^"]+)"', text[name]):
        if not match.group(1).startswith("loc_"):
            problems.append('%s passes a non-vanilla key to the game Localize: "%s"'
                            % (name, match.group(1)))

display_block = re.search(r"armor\.DISPLAY_NAME\s*=\s*\{(.*?)\n\}", text["armor"], re.S)
if display_block:
    for key in re.findall(r'"([^"]+)"', display_block.group(1)):
        if not key.startswith("loc_"):
            problems.append('armor.DISPLAY_NAME holds a non-vanilla key: "%s"' % key)

# --- 4. row bookkeeping --------------------------------------------------------
# The definitions declare ROWS = { "armor", <kinds> }, and the HUD maps each
# non-armour row to a label through ATTACK_LOC. The two lists must agree.
defs_rows = re.search(r"ROWS\s*=\s*\{([^}]*)\}", text["defs"])

if not defs_rows:
    problems.append("could not find ROWS in the definitions file")
else:
    row_names = [name for name in re.findall(r'"([a-z_]+)"', defs_rows.group(1))]
    attack_loc_block = re.search(r"ATTACK_LOC\s*=\s*\{(.*?)\n\}", text["hud"], re.S)
    loc_kinds = set(re.findall(r'([a-z_]+)\s*=\s*"attack_', attack_loc_block.group(1))) if attack_loc_block else set()

    if row_names[0] != "armor":
        problems.append("first ROWS entry is %r, not the armour row" % row_names[0])
    if set(row_names[1:]) != loc_kinds:
        problems.append("ROWS attack rows %s do not match ATTACK_LOC kinds %s"
                        % (sorted(row_names[1:]), sorted(loc_kinds)))

# --- 5. format-unsafe percent --------------------------------------------------
FORMAT_SPEC = re.compile(r"%(?![%\-+ #0-9.]*[diouxXeEfgGqcs])")
for lineno, line in enumerate(text["loc"].splitlines(), 1):
    stripped = line.strip()
    if not re.match(r'^(\[?"?[a-z\-]+"?\]?\s*=|en\s*=|\["zh|de\s*=|fr\s*=|ru\s*=|pl\s*=|es\s*=|it\s*=|ja\s*=|ko\s*=|pt)', stripped):
        continue
    match = re.search(r'=\s*"(.*)"\s*,?\s*$', stripped)
    if not match:
        continue
    value = match.group(1).replace("%%", "")
    if FORMAT_SPEC.search(value):
        problems.append("format-unsafe %% in localisation (line %d): %s" % (lineno, stripped))

# --- 6. options ---------------------------------------------------------------
setting_ids = set(re.findall(r'setting_id\s*=\s*"([^"]+)"', text["data"]))
tooltips = set(re.findall(r'tooltip\s*=\s*"([^"]+)"', text["data"]))
opt_texts = set(re.findall(r'text\s*=\s*"([^"]+)"', text["data"]))
gets = set(re.findall(r'setting\(\s*"([^"]+)"', text["main"]))
gets |= set(re.findall(r'mod:get\(\s*"([^"]+)"', text["main"] + text["hud"]))

for key in sorted(tooltips | opt_texts):
    if key not in loc_keys:
        problems.append("option text has no localisation: " + key)
for key in sorted(k for k in setting_ids if k.startswith("we_settings")):
    if key not in loc_keys:
        problems.append("option group has no localisation: " + key)
for key in sorted(gets):
    if key not in setting_ids and not key.endswith("_"):
        problems.append("setting read but never declared: " + key)

# ------------------------------------------------------------------------------
print("loc keys: %d   UI-rendered keys: %d   settings: %d   tooltips: %d   dropdowns: %d"
      % (len(loc_keys), len(wanted), len(setting_ids), len(tooltips), len(opt_texts)))

if problems:
    print("PROBLEMS:")
    for problem in sorted(set(problems)):
        print("  - " + problem)
    sys.exit(1)

print("OK: labels resolve through mod.localize, only vanilla loc_* keys reach the game")
print("    Localize, row budgets agree, no format-unsafe percent, options are labelled.")
