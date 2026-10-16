"""Parses the DshProbe damage-profile dump and re-emits the armour-relevant
structure as a faithful Lua literal, so the shipped armor.lua can be executed
against the real game data instead of against my assumptions about it.

The dump is a hybrid: JSON-style "key": value pairs, but Lua table syntax for
arrays ({0, 0.3, 1}), Lua sets ({"frag_damage"}), and a stray null. Key types
matter -- targets uses numeric 1 for the first cleave index while the JSON-style
dump writes it as a string -- so the parser keeps int and str keys distinct and
the emitter writes them back with the correct Lua syntax.
"""
import json
import re
import sys

SCALAR_TAIL = re.compile(r'-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?')
NAME_EQ = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)\s*=')
PRINTABLE = "0123456789.-"

# Keys armor.lua ever looks at; everything else is dropped to keep the emitted
# Lua file small. `name` is kept for reporting.
KEEP_TOP = {
    "name",
    "armor_damage_modifier",
    "armor_damage_modifier_ranged",
    "armor_damage_modifier_ranged_charged",
    "targets",
}


class Parser:
    def __init__(self, text):
        self.s = text
        self.i = 0
        self.n = len(text)

    def error(self, message):
        raise ValueError("%s at %d: %r" % (message, self.i, self.s[self.i:self.i + 80]))

    def ws(self):
        while self.i < self.n and self.s[self.i] in " \t\r\n":
            self.i += 1

    def peek(self):
        return self.s[self.i] if self.i < self.n else ""

    def read_string(self):
        assert self.s[self.i] == '"'
        j = self.i + 1
        buf = []
        while j < self.n:
            ch = self.s[j]
            if ch == "\\":
                buf.append(self.s[j:j + 2])
                j += 2
                continue
            if ch == '"':
                break
            buf.append(ch)
            j += 1
        raw = '"' + "".join(buf) + '"'
        self.i = j + 1
        try:
            return json.loads(raw)
        except Exception:
            return "".join(buf)

    def value(self):
        self.ws()
        c = self.peek()
        if c == "{":
            return self.table()
        if c == "[":
            return self.array()
        if c == '"':
            return self.read_string()
        if c == "<":
            j = self.s.find(">", self.i)
            if j < 0:
                self.error("unterminated <...>")
            tok = self.s[self.i:j + 1]
            self.i = j + 1
            return tok
        for word, val in (("true", True), ("false", False), ("null", None), ("nil", None)):
            if self.s.startswith(word, self.i):
                self.i += len(word)
                return val
        m = SCALAR_TAIL.match(self.s, self.i)
        if m:
            tok = m.group(0)
            self.i = m.end()
            if any(ch in tok for ch in ".eE"):
                return float(tok)
            return int(tok)
        self.error("unexpected value")

    def array(self):
        """The dump mixes JSON arrays in with Lua tables, e.g. `"key":["a","b"]`."""
        assert self.s[self.i] == "["
        self.i += 1
        out = []
        while True:
            self.ws()
            c = self.peek()
            if c == "":
                self.error("unterminated array")
            if c == "]":
                self.i += 1
                return out
            out.append(self.value())
            self.ws()
            if self.peek() == ",":
                self.i += 1
                continue
            if self.peek() == "]":
                self.i += 1
                return out
            self.error("expected , or ] in array")

    def table(self):
        assert self.s[self.i] == "{"
        self.i += 1
        out = {}
        positional = 1
        while True:
            self.ws()
            c = self.peek()
            if c == "":
                self.error("unterminated table")
            if c == "}":
                self.i += 1
                return out

            handled = False

            if c == "[":
                self.i += 1
                key = self.value()
                self.ws()
                if self.peek() != "]":
                    self.error("expected ]")
                self.i += 1
                self.ws()
                if self.peek() == "=":
                    self.i += 1
                    out[key] = self.value()
                else:
                    # `{ ["name"], other = 1 }` is a positional value, not a key.
                    out[positional] = key
                    positional += 1
                handled = True
            elif c == '"':
                key = self.read_string()
                self.ws()
                if self.peek() == ":" or self.peek() == "=":
                    self.i += 1
                    out[key] = self.value()
                    handled = True
                else:
                    # It was a positional string value after all.
                    out[positional] = key
                    positional += 1
                    handled = True
            else:
                m = NAME_EQ.match(self.s, self.i)
                if m:
                    key = m.group(1)
                    self.i = m.end()
                    out[key] = self.value()
                    handled = True

            if not handled:
                out[positional] = self.value()
                positional += 1

            self.ws()
            if self.peek() == ",":
                self.i += 1
            elif self.peek() == "}":
                self.i += 1
                return out
            elif self.peek() == "":
                self.error("unterminated table")


def lua_key(key):
    if isinstance(key, bool):
        return "[%s]" % ("true" if key else "false")
    if isinstance(key, int):
        return "[%d]" % key
    if isinstance(key, float) and key == int(key):
        return "[%d]" % int(key)
    return '[%s]' % lua_string(str(key))


def lua_string(s):
    return json.dumps(s, ensure_ascii=False)


def emit(value, out):
    if value is None:
        out.append("nil")
    elif value is True:
        out.append("true")
    elif value is False:
        out.append("false")
    elif isinstance(value, (int, float)):
        out.append(repr(value))
    elif isinstance(value, str):
        out.append(lua_string(value))
    elif isinstance(value, dict):
        out.append("{")
        first = True
        for k, v in value.items():
            if not first:
                out.append(",")
            first = False
            out.append(lua_key(k))
            out.append("=")
            emit(v, out)
        out.append("}")
    elif isinstance(value, (list, tuple)):
        # JSON arrays in the dump become plain Lua sequence tables.
        out.append("{")
        for index, item in enumerate(value):
            if index:
                out.append(",")
            emit(item, out)
        out.append("}")
    else:
        raise TypeError(type(value))


def reduce_profile(profile):
    """Keep only what armor.lua reads."""
    out = {}
    for key, value in profile.items():
        if key not in KEEP_TOP:
            continue
        if key == "targets" and isinstance(value, dict):
            targets = {}
            for tname, tbody in value.items():
                if not isinstance(tbody, dict):
                    continue
                kept = {k: v for k, v in tbody.items()
                        if k in ("armor_damage_modifier", "armor_damage_modifier_ranged",
                                 "armor_damage_modifier_ranged_charged")}
                if kept:
                    targets[tname] = kept
            if targets:
                out["targets"] = targets
            continue
        out[key] = value
    return out


def numeric_target_keys(profile):
    """Same profile, but with target keys converted to ints.

    The dump writes cleave indices as strings because JSON requires it, while the
    live game uses numeric keys. Both spellings have to work, so the harness runs
    the shipped code against each."""
    targets = profile.get("targets")
    if not isinstance(targets, dict):
        return profile

    converted = {}
    for key, value in targets.items():
        if isinstance(key, str) and key.isdigit():
            converted[int(key)] = value
        else:
            converted[key] = value

    out = dict(profile)
    out["targets"] = converted
    return out


RANGED_ANY = (
    "armor_damage_modifier_ranged",
    "armor_damage_modifier_ranged_charged",
)


def expectations(profile):
    """Independent statement of what SHOULD resolve, derived straight from the
    raw shape rather than from armor.lua."""
    targets = profile.get("targets")
    target_bodies = [t for t in targets.values() if isinstance(t, dict)] if isinstance(targets, dict) else []

    def has(key):
        if isinstance(profile.get(key), dict):
            return True
        return any(isinstance(t.get(key), dict) for t in target_bodies)

    return {
        "melee": has("armor_damage_modifier"),
        "ranged": any(has(key) for key in RANGED_ANY) or has("armor_damage_modifier"),
    }


def main():
    src = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
    parser = Parser(src)
    profiles = parser.value()
    print("parsed profiles:", len(profiles))

    reduced = {name: reduce_profile(body) for name, body in profiles.items()
               if isinstance(body, dict)}

    exp = {name: expectations(body) for name, body in reduced.items()}
    numeric = {name: numeric_target_keys(body) for name, body in reduced.items()}

    print("expect melee resolvable :", sum(1 for e in exp.values() if e["melee"]))
    print("expect ranged resolvable:", sum(1 for e in exp.values() if e["ranged"]))
    print("profiles with no expectation:", sum(1 for e in exp.values() if not e["melee"] and not e["ranged"]))

    bundle = {"profiles": reduced, "expected": exp, "profiles_numeric": numeric}

    out = []
    emit(bundle, out)
    text = "return " + "".join(out) + "\n"
    with open(sys.argv[2], "w", encoding="utf-8") as handle:
        handle.write(text)
    print("wrote", sys.argv[2], len(text), "chars")


if __name__ == "__main__":
    main()
