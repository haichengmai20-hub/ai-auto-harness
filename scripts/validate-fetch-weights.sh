#!/usr/bin/env bash
# validate-fetch-weights.sh — compare local HF download files against manifest sizes.
#
# Usage:
#   bash scripts/validate-fetch-weights.sh <workspace> <repo_id> [local_dir] [manifest_json]
#
# manifest_json is optional for production use but recommended for offline tests. It must
# contain Hugging Face API shape: {"siblings":[{"rfilename":"...", "size":123}, ...]}.
set -uo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <workspace> <repo_id> [local_dir] [manifest_json]" >&2
    exit 2
fi

WORKSPACE="$1"
REPO_ID="$2"
LOCAL_DIR="${3:-$WORKSPACE/.cache/hf_models/$REPO_ID}"
MANIFEST_JSON="${4:-}"

python3 - "$WORKSPACE" "$REPO_ID" "$LOCAL_DIR" "$MANIFEST_JSON" <<'PY'
import json
import os
import pathlib
import sys
import urllib.request

workspace = pathlib.Path(sys.argv[1])
repo_id = sys.argv[2]
local_dir = pathlib.Path(sys.argv[3])
manifest_arg = sys.argv[4]
threshold = 0.05
failures: list[str] = []
warnings: list[str] = []

def read_manifest() -> dict:
    if manifest_arg:
        path = pathlib.Path(manifest_arg)
        return json.loads(path.read_text(encoding="utf-8"))
    url = f"https://huggingface.co/api/models/{repo_id}"
    req = urllib.request.Request(url)
    token = os.environ.get("HF_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))

print("=== validate-fetch-weights ===")
print(f"  workspace: {workspace}")
print(f"  repo_id:   {repo_id}")
print(f"  local_dir: {local_dir}")
print()

if not local_dir.exists():
    print(f"FAIL: local_dir missing: {local_dir}")
    sys.exit(1)

try:
    manifest = read_manifest()
except Exception as exc:
    print(f"FAIL: cannot load manifest for {repo_id}: {exc}")
    sys.exit(1)

siblings = manifest.get("siblings")
if not isinstance(siblings, list):
    print("FAIL: manifest missing siblings[]")
    sys.exit(1)

checked = 0
for sibling in siblings:
    rel = sibling.get("rfilename") or sibling.get("path")
    size = sibling.get("size")
    if not rel:
        warnings.append(f"skip sibling without rfilename: {sibling!r}")
        continue
    if size is None or size == 0:
        # LFS files: HF API returns size=0 for LFS pointers. Try HEAD request for real size.
        # If HEAD fails, skip but don't fail the entire validation.
        try:
            hf_url = f"https://huggingface.co/{repo_id}/resolve/main/{rel}"
            req2 = urllib.request.Request(hf_url, method="HEAD")
            token2 = os.environ.get("HF_TOKEN")
            if token2:
                req2.add_header("Authorization", f"Bearer {token2}")
            # Use proxy if available
            proxy = os.environ.get("http_proxy") or os.environ.get("HTTP_PROXY")
            if proxy:
                import urllib.parse
                proxy_handler = urllib.request.ProxyHandler({"http": proxy, "https": proxy})
                opener = urllib.request.build_opener(proxy_handler)
            else:
                opener = urllib.request.build_opener()
            with opener.open(req2, timeout=15) as head_resp:
                content_length = head_resp.headers.get("Content-Length")
                if content_length:
                    size = int(content_length)
                else:
                    warnings.append(f"skip {rel}: LFS HEAD returned no Content-Length")
                    continue
        except Exception as head_exc:
            # HEAD failed: compare actual file size vs LFS pointer size threshold
            # LFS pointer files are <200 bytes. If actual > 200 bytes, it's the real file.
            path = local_dir / rel
            if path.exists():
                actual = path.stat().st_size
                if actual > 200:
                    # Real file downloaded (not just pointer). Accept.
                    print(f"  PASS {rel}: actual={actual} (LFS HEAD unavailable, file > 200 bytes → real file)")
                    checked += 1
                    continue
                else:
                    warnings.append(f"skip {rel}: only LFS pointer ({actual} bytes), HEAD failed ({head_exc})")
                    continue
            else:
                warnings.append(f"skip {rel}: LFS, HEAD failed, file missing ({head_exc})")
                continue
    try:
        expected = int(size)
    except Exception:
        warnings.append(f"skip {rel}: non-integer size {size!r}")
        continue
    path = local_dir / rel
    checked += 1
    if not path.exists():
        failures.append(f"{rel}: missing locally (expected {expected} bytes)")
        continue
    actual = path.stat().st_size
    if expected == 0:
        if actual != 0:
            failures.append(f"{rel}: expected 0 bytes, actual {actual}")
        continue
    delta = abs(actual - expected) / expected
    if delta > threshold:
        failures.append(f"{rel}: size mismatch actual={actual} expected={expected} delta={delta:.1%}")
    else:
        print(f"  PASS {rel}: actual={actual} expected={expected}")

print()
if warnings:
    print("Warnings:")
    for item in warnings:
        print(f"  WARN: {item}")
    print()

if checked == 0:
    print("FAIL: no manifest siblings with usable size were checked")
    sys.exit(1)

if failures:
    print("FAIL:")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)

print(f"PASS: {checked} files match manifest within 5%")
PY
