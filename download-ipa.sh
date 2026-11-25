#!/bin/sh
# Fetch the newest DarkPubg IPA from GitHub into ./packages.
#
#   GITHUB_TOKEN=ghp_xxx ./download-ipa.sh owner/repo
#
# Two sources, tried in order:
#   1. Latest GitHub Release asset (public repos need no token).
#   2. Actions artifact of the last successful run (needs GITHUB_TOKEN —
#      GitHub requires auth to download artifacts even on public repos).
#
# Requires: curl, unzip.

set -eu

repo="${1:-${GITHUB_REPOSITORY:-}}"
workflow="${WORKFLOW:-build-release.yml}"
branch="${BRANCH:-main}"
dest="${DEST:-$PWD/packages}"

if [ -z "$repo" ]; then
    echo "usage: $0 owner/repo   (or set GITHUB_REPOSITORY)" >&2
    exit 2
fi

mkdir -p "$dest"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

auth() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
                  -H "Accept: application/vnd.github+json" "$@"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "$@"
    fi
}

install_ipa() {
    src="$1"
    name=$(basename "$src")
    cp -f "$src" "$dest/$name"
    echo "  -> $dest/$name"
}

# --- 1. Release asset -------------------------------------------------------
echo "Checking releases on $repo"
release_json=$(auth "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null || true)

if [ -n "$release_json" ]; then
    url=$(printf '%s' "$release_json" | python3 -c '
import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit
for a in data.get("assets") or []:
    if a["name"].endswith(".ipa"):
        print(a["browser_download_url"])
        break
')
    if [ -n "$url" ]; then
        echo "Downloading release asset"
        curl -fsSL -L -o "$tmp/release.ipa" "$url"
        install_ipa "$tmp/release.ipa"
        ls -l "$dest"/*.ipa
        exit 0
    fi
    echo "  no .ipa asset on the latest release"
fi

# --- 2. Actions artifact ----------------------------------------------------
if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "No release asset found, and artifacts need GITHUB_TOKEN." >&2
    echo "Set GITHUB_TOKEN=... or push a v* tag to publish a release." >&2
    exit 1
fi

runs_json=$(auth "https://api.github.com/repos/$repo/actions/workflows/$workflow/runs?branch=$branch&status=success&per_page=1")
run_id=$(printf '%s' "$runs_json" | python3 -c '
import json,sys
data = json.load(sys.stdin)
runs = data.get("workflow_runs") or []
print(runs[0]["id"] if runs else "")
')

if [ -z "$run_id" ]; then
    echo "No successful run of $workflow on $branch." >&2
    exit 1
fi

echo "Using run $run_id"
auth "https://api.github.com/repos/$repo/actions/runs/$run_id/artifacts" |
python3 -c '
import json,sys
data = json.load(sys.stdin)
for a in data.get("artifacts") or []:
    if a.get("expired"): continue
    if a["name"].endswith("_symbols"): continue
    print(a["id"], a["name"])
' > "$tmp/artifacts.txt"

if [ ! -s "$tmp/artifacts.txt" ]; then
    echo "Run $run_id has no live IPA artifact." >&2
    exit 1
fi

while read -r id name; do
    [ -n "$id" ] || continue
    echo "Downloading artifact $name"
    auth -L -o "$tmp/$name.zip" \
        "https://api.github.com/repos/$repo/actions/artifacts/$id/zip"
    unzip -qo "$tmp/$name.zip" -d "$tmp/$name"
    found=$(find "$tmp/$name" -name '*.ipa' -type f | head -n 1)
    if [ -z "$found" ]; then
        echo "  no .ipa inside $name" >&2
        continue
    fi
    install_ipa "$found"
done < "$tmp/artifacts.txt"

ls -l "$dest"/*.ipa
