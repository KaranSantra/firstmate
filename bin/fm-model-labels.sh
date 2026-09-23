#!/usr/bin/env bash
# fm-model-labels.sh - display-only labels naming a worker's runtime, model, and
# effort, and the markers naming what currently holds its lane.
#
# Usage:
#   fm-model-labels.sh label <task-id>
#   fm-model-labels.sh marker <state key>
#   fm-model-labels.sh check
#
# label prints "<harness> · <model alias> · <effort alias>" for one task, read
# from state/<task-id>.meta's harness=, model=, and effort= fields, for example
# "claude · opus5 · hi". A model matches the lookup by its exact
# [models."<recorded model>"] key or by any value in that entry's
# also_recorded_as list. A model with no alias prints its recorded name with
# any leading provider path ("anthropic/") and any leading "<harness>-" prefix
# removed, so the label never repeats the runtime ("claude · opus-5-5", not
# "claude · claude-opus-5-5"); the recorded name is kept whole if nothing would
# remain. An effort word with no alias prints its raw name. Neither is ever an
# error. A model or effort segment whose field is
# absent, empty, "-", or "default" is omitted. A missing lookup file silently
# falls back to unaliased names; an invalid one also falls back and adds one warning
# on stderr. Exit 0 with the label, or 1 when the task has no readable record or
# records no harness.
#
# marker prints the display marker for one pipeline state, for example "rvx"
# for review, and an empty line for a state with no marker - never a
# placeholder. bin/fm-state-marker.sh is its caller and owns which state keys
# exist and when the marker is shown, cleared, and refreshed. The review
# default ships below, so it renders before the lookup file exists; every other
# state is marked only once the lookup gives it a glyph.
#
# marker is deliberately STRICTER than label about a broken lookup: an
# unparseable or invalid file makes it print nothing and exit 1, saying why,
# rather than falling back. The marker is the captain's own configuration
# surface, so a typo must be visible instead of quietly showing him the wrong
# symbol, whereas a label still wants to name the worker at all.
#
# check validates the lookup file. It prints one "warning:" line per unknown
# key, one "error:" line per defect, and a closing summary. Unknown keys are
# warnings, never failures. When the generated catalog
# <data>/model-effort-catalog.md exists, check also prints one "info:" line per
# catalog model with no alias; that report never changes the result. Exit 0 for
# a valid file (with or without warnings), 1 for an absent or invalid file.
#
# The lookup holds ONLY short display aliases: model names, effort words, and
# pipeline-state markers.
# The generated catalog (data/model-effort-catalog.md, rebuilt by
# data/model-catalog/refresh.sh) is the single owner of which models exist and
# which effort levels each accepts, so nothing here validates or restricts an
# effort level, and check only reads that catalog's model rows for its info
# report. No dispatch step reads the lookup, so it never decides which harness,
# model, or effort a worker gets (AGENTS.md section 4). Update it only when the
# captain asks. bin/fm-spawn.sh applies the label to a Herdr-backed worker after
# launch and after relaunch through bin/backends/herdr.sh's
# fm_backend_herdr_report_display_agent.
#
# Paths: the lookup file is FM_MODEL_LABELS_FILE when set, otherwise
# <config>/model-labels.toml, where <config> is FM_CONFIG_OVERRIDE or
# $FM_HOME/config. Task records come from FM_STATE_OVERRIDE or $FM_HOME/state,
# and the catalog from FM_DATA_OVERRIDE or $FM_HOME/data. python3 reads the
# lookup; without python3, label falls back to unaliased names with one warning and
# check fails.
#
# Accepted lookup syntax is this TOML subset, parsed without a TOML library so
# any python3 works:
#   - blank lines and # comments, including trailing comments
#   - [table] headers whose dotted keys are bare or "quoted"
#   - key = value, where value is a "basic string" (only \" and \\ escapes),
#     an integer, true or false, or a one-line array of basic strings
# Anything else is an error, as is a key or table defined twice.
#
# Schema (schema = 1):
#   [meta]                       schema (integer), updated (string)
#   [models."<recorded model>"]  alias (string, required), also_recorded_as
#                                (string array), provider, verified, note
#                                (strings)
#   [effort.aliases]             <effort word> = "<short alias>"
#   [states.glyphs]              <pipeline state> = "<marker>"
# A recorded model name claimed by more than one [models] entry is an error.
# A marker is any non-blank text, letters allowed, no longer than
# GLYPH_MAX_CHARS below, because the sidebar row is horizontally tight. A state
# name this release does not report is a warning, never a failure, so the lookup
# survives a pipeline that renames or adds a step.
#
# The catalog info report reads only table rows whose first cell is a single
# `model` and list lines that are a single `model`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LABELS_FILE="${FM_MODEL_LABELS_FILE:-$CONFIG/model-labels.toml}"
CATALOG_FILE="$DATA/model-effort-catalog.md"
SEP=' · '

usage() {
  sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

# model_labels_py <mode> <file> ...: the one lookup parser and schema validator.
# mode=aliases <model> <effort> prints the model alias line then the effort
# alias line; mode=check <catalog> prints the validation report.
model_labels_py() {
  python3 - "$@" <<'PY'
import os
import re
import sys

BARE = re.compile(r"[A-Za-z0-9_-]+")
SCALAR = re.compile(r"[+-]?[0-9]+|true|false")
CATALOG_ROW = re.compile(r"^\|\s*`([^`]+)`\s*\|")
CATALOG_ITEM = re.compile(r"^-\s+`([^`]+)`\s*$")

# The state keys a marker can be configured for: the pipeline steps the run
# reports (bin/fm-crew-state.sh names them) plus the two keys that are not
# steps, fix for an auto-fix round and decision for a lane parked at a gate.
STATE_KEYS = (
    "intent", "review", "test", "lint", "document", "push", "pr", "ci",
    "fix", "decision",
)

# Display-only markers shipped so the marker works with no lookup file at all.
# Only the review is marked by default - "rv" for review, "x" for the Codex
# reviewer - because which lane is with the reviewer is the one thing the
# sidebar cannot otherwise show; every other state stays bare until
# [states.glyphs] in the lookup gives it a glyph, and that table also
# overrides this entry.
DEFAULT_STATE_GLYPHS = {
    "review": "rvx",
}
# A marker is at most three characters, letters allowed, because the sidebar
# row is horizontally tight.
GLYPH_MAX_CHARS = 3


class ParseError(Exception):
    pass


def skip_ws(s, i):
    while i < len(s) and s[i] in " \t":
        i += 1
    return i


def read_string(s, i, n):
    out = []
    i += 1
    while i < len(s):
        c = s[i]
        if c == '"':
            return "".join(out), i + 1
        if c == "\\":
            if i + 1 < len(s) and s[i + 1] in '"\\':
                out.append(s[i + 1])
                i += 2
                continue
            raise ParseError("line %d: unsupported escape in a string" % n)
        out.append(c)
        i += 1
    raise ParseError("line %d: unterminated string" % n)


def read_key(s, i, n):
    parts = []
    while True:
        i = skip_ws(s, i)
        if i < len(s) and s[i] == '"':
            key, i = read_string(s, i, n)
        else:
            m = BARE.match(s, i)
            if not m:
                raise ParseError("line %d: expected a key" % n)
            key, i = m.group(0), m.end()
        parts.append(key)
        i = skip_ws(s, i)
        if i < len(s) and s[i] == ".":
            i += 1
            continue
        return parts, i


def read_value(s, i, n):
    i = skip_ws(s, i)
    if i >= len(s) or s[i] == "#":
        raise ParseError("line %d: missing value" % n)
    if s[i] == '"':
        return read_string(s, i, n)
    if s[i] == "[":
        items = []
        i = skip_ws(s, i + 1)
        if i < len(s) and s[i] == "]":
            return items, i + 1
        while True:
            if i >= len(s) or s[i] != '"':
                raise ParseError("line %d: an array must hold strings and close on the same line" % n)
            item, i = read_string(s, i, n)
            items.append(item)
            i = skip_ws(s, i)
            if i < len(s) and s[i] == ",":
                i = skip_ws(s, i + 1)
                if i < len(s) and s[i] == "]":
                    return items, i + 1
                continue
            if i < len(s) and s[i] == "]":
                return items, i + 1
            raise ParseError("line %d: an array must hold strings and close on the same line" % n)
    m = SCALAR.match(s, i)
    if not m:
        raise ParseError("line %d: unsupported value" % n)
    text = m.group(0)
    if text == "true":
        return True, m.end()
    if text == "false":
        return False, m.end()
    return int(text), m.end()


def expect_end(s, i, n):
    i = skip_ws(s, i)
    if i < len(s) and s[i] != "#":
        raise ParseError("line %d: unexpected text after the value" % n)


def descend(node, parts, n):
    for part in parts:
        node = node.setdefault(part, {})
        if not isinstance(node, dict):
            raise ParseError("line %d: %s is already a value, not a table" % (n, part))
    return node


def parse(text):
    root, defined = {}, set()
    current = root
    for n, line in enumerate(text.splitlines(), 1):
        i = skip_ws(line, 0)
        if i >= len(line) or line[i] == "#":
            continue
        if line[i] == "[":
            if line.startswith("[[", i):
                raise ParseError("line %d: arrays of tables are not supported" % n)
            parts, j = read_key(line, i + 1, n)
            j = skip_ws(line, j)
            if j >= len(line) or line[j] != "]":
                raise ParseError("line %d: expected ] to close the table header" % n)
            expect_end(line, j + 1, n)
            if tuple(parts) in defined:
                raise ParseError("line %d: table %s is defined twice" % (n, ".".join(parts)))
            defined.add(tuple(parts))
            current = descend(root, parts, n)
            continue
        parts, j = read_key(line, i, n)
        j = skip_ws(line, j)
        if j >= len(line) or line[j] != "=":
            raise ParseError("line %d: expected = after the key" % n)
        value, j = read_value(line, j + 1, n)
        expect_end(line, j, n)
        node = descend(current, parts[:-1], n)
        if parts[-1] in node:
            raise ParseError("line %d: key %s is set twice" % (n, parts[-1]))
        node[parts[-1]] = value
    return root


def nonempty_string(v):
    return isinstance(v, str) and v.strip() != ""


def validate(doc):
    errors, warnings = [], []
    for key in doc:
        if key not in ("meta", "models", "effort", "states"):
            warnings.append("unknown top-level key %s" % key)
    meta = doc.get("meta", {})
    if not isinstance(meta, dict):
        errors.append("meta must be a table")
        meta = {}
    for key, v in meta.items():
        if key == "schema":
            if not isinstance(v, int) or isinstance(v, bool):
                errors.append("meta.schema must be an integer")
            elif v != 1:
                errors.append("meta.schema %d is not supported (expected 1)" % v)
        elif key == "updated":
            if not isinstance(v, str):
                errors.append("meta.updated must be a string")
        else:
            warnings.append("unknown key meta.%s" % key)
    models = doc.get("models", {})
    if not isinstance(models, dict):
        errors.append("models must be a table")
        models = {}
    claimed = {}
    for name, entry in models.items():
        where = 'models."%s"' % name
        if not isinstance(entry, dict):
            errors.append("%s must be a table" % where)
            continue
        for key, v in entry.items():
            if key in ("alias", "provider", "verified", "note"):
                if not nonempty_string(v):
                    errors.append("%s.%s must be a non-empty string" % (where, key))
            elif key == "also_recorded_as":
                if not isinstance(v, list) or not all(nonempty_string(x) for x in v):
                    errors.append("%s.also_recorded_as must be an array of non-empty strings" % where)
            else:
                warnings.append("unknown key %s.%s" % (where, key))
        if "alias" not in entry:
            errors.append("%s is missing alias" % where)
        names = [name]
        if isinstance(entry.get("also_recorded_as"), list):
            names += entry["also_recorded_as"]
        for recorded in names:
            owner = claimed.setdefault(recorded, name)
            if owner != name:
                errors.append('recorded name "%s" is claimed by both models."%s" and %s' % (recorded, owner, where))
    effort = doc.get("effort", {})
    if not isinstance(effort, dict):
        errors.append("effort must be a table")
        effort = {}
    for key, v in effort.items():
        if key != "aliases":
            warnings.append("unknown key effort.%s" % key)
            continue
        if not isinstance(v, dict):
            errors.append("effort.aliases must be a table")
            continue
        for word, alias in v.items():
            if not nonempty_string(alias):
                errors.append("effort.aliases.%s must be a non-empty string" % word)
    states = doc.get("states", {})
    if not isinstance(states, dict):
        errors.append("states must be a table")
        states = {}
    for key, v in states.items():
        if key != "glyphs":
            warnings.append("unknown key states.%s" % key)
            continue
        if not isinstance(v, dict):
            errors.append("states.glyphs must be a table")
            continue
        for name, glyph in v.items():
            where = "states.glyphs.%s" % name
            if not nonempty_string(glyph):
                errors.append("%s must be a non-empty string" % where)
                continue
            if len(glyph) > GLYPH_MAX_CHARS:
                errors.append(
                    "%s is %d characters; a marker is at most %d characters because the sidebar row is tight"
                    % (where, len(glyph), GLYPH_MAX_CHARS)
                )
            if name not in STATE_KEYS:
                warnings.append("%s names no pipeline state this release reports" % where)
    return errors, warnings


def load(path):
    with open(path, encoding="utf-8") as f:
        doc = parse(f.read())
    errors, warnings = validate(doc)
    return doc, errors, warnings


def recorded_names(doc):
    names = set()
    for name, entry in doc.get("models", {}).items():
        names.add(name)
        if isinstance(entry, dict) and isinstance(entry.get("also_recorded_as"), list):
            names.update(entry["also_recorded_as"])
    return names


def catalog_models(path):
    found = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = CATALOG_ROW.match(line) or CATALOG_ITEM.match(line)
                if m and m.group(1) not in found:
                    found.append(m.group(1))
    except (OSError, UnicodeDecodeError):
        return None
    return found


def model_alias(doc, model):
    models = doc.get("models", {})
    entry = models.get(model)
    if isinstance(entry, dict) and nonempty_string(entry.get("alias")):
        return entry["alias"]
    for entry in models.values():
        if isinstance(entry, dict) and model in (entry.get("also_recorded_as") or []):
            return entry["alias"]
    return ""


def check(path, catalog):
    if not os.path.isfile(path):
        print("error: no lookup file at %s" % path)
        return 1
    try:
        doc, errors, warnings = load(path)
    except (OSError, UnicodeDecodeError, ParseError) as exc:
        print("error: %s" % exc)
        return 1
    for w in warnings:
        print("warning: %s" % w)
    for e in errors:
        print("error: %s" % e)
    if errors:
        print("invalid: %s has %d error(s); labels fall back to unaliased names until it is fixed" % (path, len(errors)))
        return 1
    if os.path.isfile(catalog):
        models = catalog_models(catalog)
        if models is None:
            print("info: %s could not be read for the alias report" % catalog)
        else:
            known = recorded_names(doc)
            for model in models:
                if model not in known:
                    print("info: catalog model %s has no alias and shows its unaliased name" % model)
    print("ok: %s is valid (%d warning(s))" % (path, len(warnings)))
    return 0


def marker(path, key):
    """The display marker for one pipeline state, or an empty line for none.

    A lookup file that cannot be parsed, or that has any schema error, is a
    LOUD failure here rather than a silent fall back to the defaults: the
    marker is the captain's own configuration surface, so a typo in it must be
    visible instead of quietly showing him a stale or wrong symbol. That is the
    deliberate difference from the alias path above, which keeps showing raw
    model names so a worker still gets a label at all.
    """
    glyphs = dict(DEFAULT_STATE_GLYPHS)
    if os.path.isfile(path):
        try:
            doc, errors, _ = load(path)
        except (OSError, UnicodeDecodeError, ParseError) as exc:
            sys.stderr.write("error: %s could not be read: %s\n" % (path, exc))
            return 1
        if errors:
            sys.stderr.write(
                "error: %s has %d error(s), so no marker is shown; run bin/fm-model-labels.sh check\n"
                % (path, len(errors))
            )
            return 1
        configured = doc.get("states", {}).get("glyphs", {})
        if isinstance(configured, dict):
            for name, glyph in configured.items():
                if nonempty_string(glyph):
                    glyphs[name] = glyph
    print(glyphs.get(key, ""))
    return 0


def main():
    mode, path = sys.argv[1], sys.argv[2]
    if mode == "check":
        return check(path, sys.argv[3])
    if mode == "marker":
        return marker(path, sys.argv[3])
    model, effort = sys.argv[3], sys.argv[4]
    doc = {}
    if os.path.isfile(path):
        try:
            doc, errors, _ = load(path)
        except (OSError, UnicodeDecodeError, ParseError):
            errors = ["unreadable"]
        if errors:
            doc = {}
            sys.stderr.write("warning: %s is invalid, so labels use unaliased names; run bin/fm-model-labels.sh check\n" % path)
    aliases = doc.get("effort", {}).get("aliases", {})
    # An empty model line means no alias matched; cmd_label names the model.
    print(model_alias(doc, model) if model else "")
    print(aliases.get(effort, effort) if effort else "")
    return 0


sys.exit(main())
PY
}

# label_field <meta> <key>: the recorded value, or empty for an unset marker.
label_field() {
  local value
  value=$(fm_meta_get "$1" "$2")
  case "$value" in
    - | default) value= ;;
  esac
  printf '%s' "$value"
}

# unaliased_model <model> <harness>: the display name for a model with no
# alias. It drops a leading provider path and a leading "<harness>-" prefix,
# because the label already names the runtime, and keeps the recorded name
# whole when nothing would remain.
unaliased_model() {
  local name=${1##*/}
  case "$name" in
    "$2"-?*) name=${name#"$2"-} ;;
  esac
  printf '%s' "${name:-$1}"
}

cmd_label() {
  local id=${1:-} meta harness model effort out model_alias effort_alias label
  case "$id" in
    '' | */* | .*) die "label needs a task id" 2 ;;
  esac
  meta="$STATE/$id.meta"
  [ -r "$meta" ] || die "no readable record for task $id at $meta"
  harness=$(fm_meta_get "$meta" harness)
  [ -n "$harness" ] || die "task $id records no harness"
  model=$(label_field "$meta" model)
  effort=$(label_field "$meta" effort)
  model_alias=
  effort_alias=$effort
  if ! command -v python3 >/dev/null 2>&1; then
    [ ! -e "$LABELS_FILE" ] || printf 'warning: python3 is not installed, so labels use unaliased names\n' >&2
  elif out=$(model_labels_py aliases "$LABELS_FILE" "$model" "$effort"); then
    { IFS= read -r model_alias; IFS= read -r effort_alias; } <<<"$out"
  else
    printf 'warning: %s could not be read, so labels use unaliased names\n' "$LABELS_FILE" >&2
  fi
  [ -n "$model_alias" ] || [ -z "$model" ] || model_alias=$(unaliased_model "$model" "$harness")
  label=$harness
  [ -z "$model_alias" ] || label="$label$SEP$model_alias"
  [ -z "$effort_alias" ] || label="$label$SEP$effort_alias"
  printf '%s\n' "$label"
}

cmd_check() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required to check $LABELS_FILE"
  model_labels_py check "$LABELS_FILE" "$CATALOG_FILE"
}

# marker <state key>: the display marker for one pipeline state. Prints an
# empty line - never a placeholder - for a state this release does not mark,
# which is what keeps an unknown, absent, or unreadable state showing nothing
# at all on the sidebar row. Exits non-zero, having said why, when the lookup
# file itself is unreadable or invalid.
cmd_marker() {
  local key=${1:-}
  case "$key" in
    '' | */* | .*) die "marker needs a state key" 2 ;;
  esac
  command -v python3 >/dev/null 2>&1 || die "python3 is required to read $LABELS_FILE"
  model_labels_py marker "$LABELS_FILE" "$key"
}

case "${1:-}" in
  label) shift; cmd_label "$@" ;;
  marker) shift; cmd_marker "$@" ;;
  check) cmd_check ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
