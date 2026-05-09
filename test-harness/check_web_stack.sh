#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ps/dcr/claudecode/claudecode_sourcecode1"
cd "$ROOT"

ok() { printf "[OK] %s\n" "$1"; }
warn() { printf "[WARN] %s\n" "$1"; }
has_pattern() {
  local pattern="$1"
  local file="$2"
  grep -Eq "$pattern" "$file"
}

printf "== Web Tool Readiness Check ==\n"

# 1) Core files
for f in \
  src/tools/WebFetchTool/preapproved.ts \
  src/tools/WebFetchTool/WebFetchTool.ts \
  src/tools/WebFetchTool/utils.ts \
  src/utils/hooks/ssrfGuard.ts \
  src/tools/WebSearchTool/WebSearchTool.ts \
  src/tools/WebSearchTool/prompt.ts \
  src/utils/settings/types.ts; do
  if [[ -f "$f" ]]; then
    ok "found $f"
  else
    warn "missing $f"
  fi
done

# 2) Runtime dependencies
pm_ls_output="$('/home/ps/dcr_claude_home/.bun/bin/bun' pm ls 2>/dev/null || true)"

if [[ "$pm_ls_output" == *"turndown@"* ]]; then
  ok "turndown installed"
else
  warn "turndown not installed (run: bun add turndown)"
fi

if [[ "$pm_ls_output" == *"axios@"* ]]; then
  ok "axios installed"
else
  warn "axios not installed"
fi

if [[ "$pm_ls_output" == *"lru-cache@"* ]]; then
  ok "lru-cache installed"
else
  warn "lru-cache not installed"
fi

# 3) Local permissions config
if [[ -f .claude/settings.local.json ]]; then
  ok "found .claude/settings.local.json"
  if has_pattern '"WebSearch"' .claude/settings.local.json; then
    ok "WebSearch permission preset found"
  else
    warn "WebSearch permission preset missing"
  fi
  if has_pattern 'WebFetch\(domain:' .claude/settings.local.json; then
    ok "WebFetch domain allow rules found"
  else
    warn "WebFetch domain allow rules missing"
  fi
else
  warn ".claude/settings.local.json missing"
fi

# 4) API key hints
if [[ -n "${TAVILY_API_KEY:-}" || -n "${BRAVE_SEARCH_API_KEY:-}" || -n "${SERPAPI_API_KEY:-}" ]]; then
  ok "search backend key present in env"
else
  warn "no search backend key in env (WebSearch may return empty)"
fi

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  ok "OPENAI_API_KEY present"
else
  warn "OPENAI_API_KEY missing"
fi

printf "== Check Complete ==\n"
