#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != "--instrument" ) ]]; then
    echo "Usage: bash $0 NEW_WORKTREE [--instrument]" >&2
    exit 2
fi

destination="$1"
if [[ -e "$destination" || -L "$destination" ]]; then
    echo "Choose a new worktree path. Already exists at $destination" >&2
    exit 2
fi
destination="$(cd -- "$(dirname -- "$destination")" && pwd -P)/$(basename -- "$destination")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository="$(git -C "$script_dir" rev-parse --show-toplevel)"
upstream=f925129209afd55927a0201d82285b8fa4b7ba30
recipe=1b9e58ae9c6d2714d7a022fe135cc32e2dc0f9c4

stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
git -C "$repository" show "$recipe:a19-overlay.zip" > "$stage/overlay.zip"
git -C "$repository" show "$recipe:.github/workflows/a19-build.yml" > "$stage/workflow.yml"

python3 - "$stage" <<'PY'
import hashlib
import pathlib
import sys

stage = pathlib.Path(sys.argv[1])
expected = "dfd0e7c1bde9029aec5c2d2347086a15342995da135fec54842587796e04400f"
if hashlib.sha256((stage / "overlay.zip").read_bytes()).hexdigest() != expected:
    sys.exit("MeloNX v0.6 overlay hash mismatch")

lines = (stage / "workflow.yml").read_text().splitlines(keepends=True)
indent = " " * 10
for phase in ("review", "lab", "v05", "v06"):
    marker = f"A19_{phase.upper()}_PATCH"
    opener = f'{indent}cat > "$RUNNER_TEMP/a19-{phase}.patch" <<\'{marker}\'\n'
    start = lines.index(opener) + 1
    end = lines.index(f"{indent}{marker}\n", start)
    patch = lines[start:end]
    if not all(line.startswith(indent) for line in patch):
        sys.exit(f"Unexpected indentation in historical {phase} patch")
    (stage / f"{phase}.patch").write_text("".join(line[len(indent):] for line in patch))
PY

git -C "$repository" worktree add --detach "$destination" "$upstream"
unzip -oq "$stage/overlay.zip" -d "$destination"
for phase in review lab v05 v06; do
    git -C "$destination" apply --check "$stage/$phase.patch"
    git -C "$destination" apply "$stage/$phase.patch"
done
chmod +x "$destination"/distribution/ios/a19/*.sh "$destination/distribution/ios/build.sh"

if [[ "${2:-}" == "--instrument" ]]; then
    git -C "$destination" apply --check "$script_dir/pipeline-telemetry.patch"
    git -C "$destination" apply "$script_dir/pipeline-telemetry.patch"
fi
