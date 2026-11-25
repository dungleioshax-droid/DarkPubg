#!/bin/sh
# Fetch the newest DarkPubg IPA from GitHub Actions into ./packages.
#
#   GITHUB_TOKEN=ghp_xxx ./download-ipa.sh owner/repo
#
# Without a token only public artifacts work, via the public runs API.
# Requires: curl, unzip. No gh CLI, so it runs on any box.

set -eu

repo="${1:-${GITHUB_REPOSITORY:-}}"
workflow="${WORKFLOW:-build-release.yml}"
branch="${BRANCH:-main}"
dest="${DEST:-$PWD/packages}"
run_id="${RUN_ID:-}"

if [ -z "$repo" ]; then
    echo "usage: $0 owner/repo   (or set GITHUB_REPOSITORY)" >&2
    exit 2
fi

api="https://api.github.com/repos/$repo/actions/workflows/$workflow/runs"
auth_header=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth_header="Authorization: Bearer $GITHUB_TOKEN"
fi

fetch() {
    if [ -n "$auth_header" ]; then
        curl -fsSL -H "$auth_header" -H "Accept: application/vnd.github+json" "$1"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "$1"
    fi
}

if [ -z "$run_id" ]; then
    echo "Looking up the latest successful run of $workflow on $repo"
    runs_json=$(fetch "$api?branch=$branch&status=success&per_page=1")
    run_id=$(printf '%s' "$runs_json" | python3 -c '
import json,sys
data = json.load(sys.stdin)
runs = data.get("workflow_runs") or []
print(runs[0]["id"] if runs else "")
')
fi

if [ -z "$run_id" ]; then
    echo "No successful run found. Trigger it first, or pass RUN_ID=<id>." >&2
    exit 1
fi

echo "Using run $run_id"
artifacts_json=$(fetch "https://api.github.com/repos/$repo/actions/runs/$run_id/artifacts")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# Pull every artifact that is not the dSYM bundle, newest upload first.
printf '%s' "$artifacts_json" | python3 -c '
import json,sys
data = json.load(sys.stdin)
for a in data.get("artifacts") or []:
    if a.get("expired"): continue
    if a["name"].endswith("_symbols"): continue
    print(a["id"], a["name"])
' | while read -r id name; do
    [ -n "$id" ] || continue
    out="$tmp/$name.zip"
    echo "Downloading $name"
    if [ -n "$auth_header" ]; then
        curl -fsSL -H "$auth_header" -L \
            "https://api.github.com/repos/$repo/actions/artifacts/$id/zip" -o "$out"
    else
        curl -fsSL -L \
            "https://api.github.com/repos/$repo/actions/artifacts/$id/zip" -o "$out"
    fi
    mkdir -p "$tmp/$name"
    unzip -qo "$out" -d "$tmp/$name"
    found=$(find "$tmp/$name" -name '*.ipa' -type f | head -n 1)
    if [ -z "$found" ]; then
        echo "  no .ipa inside $name" >&2
        continue
    fi
    mkdir -p "$dest"
    cp -f "$found" "$dest/"
    echo "  -> $dest/$(basename "$found")"
done

ls -l "$dest"/*.ipa 2>/dev/null || {
    echo "Nothing landed in $dest" >&2
    exit 1
}
