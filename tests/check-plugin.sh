#!/usr/bin/env bash
# Acceptance tests for the plugin/marketplace manifests (.claude-plugin/).
# Structural truths are asserted with python3 (the suite's declared parser
# dependency — no jq, per Stage 2); the authoritative runtime check
# (`claude plugin validate --strict`) runs only where the claude CLI exists
# and is SKIPPED LOUDLY elsewhere, keeping the check count stable.
# Bash 3.2 compatible; no GNU-only flags.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
PLUGIN="$ROOT/.claude-plugin/plugin.json"
MARKET="$ROOT/.claude-plugin/marketplace.json"

pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$*"; fail=$((fail + 1)); }

command -v python3 >/dev/null 2>&1 || { printf 'FAIL: python3 missing\n'; exit 1; }
export PYTHONIOENCODING=utf-8

# ---- 1. structural contract (parse, required fields, cross-consistency) -----
out=$(python3 - "$PLUGIN" "$MARKET" <<'PLUGIN_PY'
import json, re, sys

plugin_file, market_file = sys.argv[1], sys.argv[2]
errs = []

def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

try:
    plugin = load(plugin_file)
except (OSError, ValueError) as e:
    print("plugin.json unreadable/unparseable: %s" % e)
    sys.exit(1)
try:
    market = load(market_file)
except (OSError, ValueError) as e:
    print("marketplace.json unreadable/unparseable: %s" % e)
    sys.exit(1)

KEBAB = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

name = plugin.get("name")
if not (isinstance(name, str) and KEBAB.match(name)):
    errs.append("plugin.name missing or not kebab-case: %r" % name)
if not plugin.get("description"):
    errs.append("plugin.description missing (namespace UX depends on it)")
if not (isinstance(plugin.get("author"), dict) and plugin["author"].get("name")):
    errs.append("plugin.author.name missing")
for url_field in ("homepage", "repository"):
    v = plugin.get(url_field)
    if not (isinstance(v, str) and v.startswith("https://")):
        errs.append("plugin.%s missing or not an https URL: %r" % (url_field, v))
if "version" in plugin:
    errs.append("plugin.version present — updates are commit-SHA-tracked "
                "by decision (CLAUDEX-ADOPTION Stage 1); a stale manual "
                "version would FREEZE auto-updates")

if not (isinstance(market.get("name"), str) and KEBAB.match(market["name"])):
    errs.append("marketplace.name missing or not kebab-case")
if not (isinstance(market.get("owner"), dict) and market["owner"].get("name")):
    errs.append("marketplace.owner.name missing")
plugins = market.get("plugins")
if not (isinstance(plugins, list) and len(plugins) == 1):
    errs.append("marketplace.plugins must list exactly this one plugin")
else:
    entry = plugins[0]
    if entry.get("name") != name:
        errs.append("marketplace entry name %r != plugin.json name %r"
                    % (entry.get("name"), name))
    if entry.get("source") != "./":
        errs.append("marketplace entry source must be './' (single-plugin "
                    "repo): %r" % entry.get("source"))
    if "version" in entry:
        errs.append("marketplace entry pins a version — same freeze hazard "
                    "as plugin.version")

for e in errs:
    print(e)
sys.exit(1 if errs else 0)
PLUGIN_PY
)
if [ $? -eq 0 ]; then ok; else bad "manifest contract: $out"; fi

# ---- 2. LF bytes (the plugin cache is a byte copy — CR would ship as-is) ----
for f in "$PLUGIN" "$MARKET"; do
  if LC_ALL=C grep -q $'\r' "$f"; then bad "CR bytes in ${f##*/}"; else ok; fi
done

# ---- 3. runtime validation where the claude CLI exists (skip LOUDLY else) ---
# NOT --strict: strict warns on the ABSENT version field, and omitting it is
# deliberate (commit-SHA-tracked updates; a stale manual semver would freeze
# auto-updates — the hazard check 1 guards). Non-strict still fails on every
# real manifest error.
if command -v claude >/dev/null 2>&1; then
  if claude plugin validate "$ROOT" >/dev/null 2>&1; then ok
  else bad "claude plugin validate rejected the manifests"; fi
  # The manifest pass above does NOT open skill frontmatter — a malformed
  # SKILL.md would ship silently. Validate the distributed components too
  # (strict here: skills carry no deliberate warnings).
  if claude plugin validate "$ROOT/skills" --strict >/dev/null 2>&1; then ok
  else bad "claude plugin validate --strict rejected the skills directory"; fi
else
  printf 'SKIP (counted ok x2): claude CLI absent — validation ran only structurally\n'
  ok; ok
fi

printf 'check-plugin: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
