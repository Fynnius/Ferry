#!/bin/zsh
# Builds a throwaway fleet of repos in every state Ferry shows, with local bare repos as
# remotes. For screenshots and manual testing — never point Ferry's tests at real repos.
# Usage: scripts/make-demo-fleet.sh <empty-or-missing-dir>
set -euo pipefail
ROOT="${1:?target dir}"
rm -rf "$ROOT"
mkdir -p "$ROOT/remotes" "$ROOT/Harbor" "$ROOT/Atlas" "$ROOT/Personal"
ROOT="$(cd "$ROOT" && pwd -P)"
export GIT_CONFIG_GLOBAL="$ROOT/.gitconfig" GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<CFG
[user]
    name = Sam Rivera
    email = sam@example.com
[init]
    defaultBranch = main
[commit]
    gpgsign = false
CFG
g() { git -C "$@"; }

# repo <dir> <name> [files...]: bare remote + clone with an initial commit
repo() {
  local dir=$1 name=$2; shift 2
  git init -q --bare "$ROOT/remotes/$name.git"
  git clone -q "$ROOT/remotes/$name.git" "$ROOT/$dir/$name" 2>/dev/null
  local r="$ROOT/$dir/$name"
  echo "# $name" > "$r/README.md"
  for f in "$@"; do mkdir -p "$r/$(dirname "$f")"; echo "// $f" > "$r/$f"; done
  g "$r" add -A && g "$r" commit -q -m "Initial commit"
  g "$r" push -q -u origin main 2>/dev/null
}
commit() { local r=$1 f=$2 m=$3; mkdir -p "$r/$(dirname "$f")"; echo "$m" >> "$r/$f"; g "$r" add -A; g "$r" commit -q -m "$m"; }

# Harbor — a multi-repo product
repo Harbor harbor-web src/routes/checkout/+page.svelte src/lib/cart/total.ts src/lib/cart/legacy-total.ts package.json
W="$ROOT/Harbor/harbor-web"
g "$W" switch -q -c feature/checkout
commit "$W" src/lib/cart/total.ts "Add cart total helper"
g "$W" push -q -u origin feature/checkout 2>/dev/null
commit "$W" src/lib/cart/total.ts "Handle discounts in cart total"
echo "<script>let total = 0</script>" >> "$W/src/routes/checkout/+page.svelte"
echo "export const round = (n) => n" >> "$W/src/lib/cart/total.ts"
rm "$W/src/lib/cart/legacy-total.ts"
echo "test('total', () => {})" > "$W/src/lib/cart/total.test.ts"

repo Harbor harbor-api app/orders/service.py app/orders/models.py
A="$ROOT/Harbor/harbor-api"
mkdir -p "$A/migrations" && echo "CREATE INDEX orders_created ON orders(created_at);" > "$A/migrations/0042_orders_index.sql"
echo "def total(order): ..." >> "$A/app/orders/service.py"
g "$A" add migrations app/orders/service.py
echo "## Running locally" >> "$A/README.md"

repo Harbor harbor-docs docs/index.md docs/api.md
D="$ROOT/Harbor/harbor-docs"
git clone -q "$ROOT/remotes/harbor-docs.git" "$ROOT/.other-docs" 2>/dev/null
for i in 1 2 3; do commit "$ROOT/.other-docs" docs/api.md "Document endpoint $i"; done
g "$ROOT/.other-docs" push -q 2>/dev/null
g "$D" fetch -q

repo Harbor harbor-ios Sources/App.swift
I="$ROOT/Harbor/harbor-ios"
g "$I" switch -q -c release/2.4
commit "$I" Sources/App.swift "Bump version to 2.4"

repo Harbor harbor-site index.html styles.css

# Atlas — a tool and its CLI
repo Atlas atlas Sources/Atlas/Map.swift Package.swift
T="$ROOT/Atlas/atlas"
g "$T" switch -q -c vector-tiles
commit "$T" Sources/Atlas/Vector.swift "Parse vector tiles"
commit "$T" Sources/Atlas/Vector.swift "Style vector layers"
g "$T" switch -q main
commit "$T" Sources/Atlas/Map.swift "Add tile cache"
g "$T" merge -q --no-ff vector-tiles -m "Merge branch 'vector-tiles'"
commit "$T" Sources/Atlas/Map.swift "Evict least-recently-used tiles"
repo Atlas atlas-cli Sources/CLI/main.swift
echo "print(\"wip\")" >> "$ROOT/Atlas/atlas-cli/Sources/CLI/main.swift"
g "$ROOT/Atlas/atlas-cli" stash push -q -m "Try a progress bar"

# Personal
repo Personal dotfiles zsh/.zshrc git/.gitconfig
echo "alias gs='git status'" >> "$ROOT/Personal/dotfiles/zsh/.zshrc"
repo Personal blog posts/hello.md
mkdir -p "$ROOT/Personal/swift-sandbox" && git -C "$ROOT/Personal/swift-sandbox" init -q
echo "print(1)" > "$ROOT/Personal/swift-sandbox/main.swift"
g "$ROOT/Personal/swift-sandbox" add -A && g "$ROOT/Personal/swift-sandbox" commit -q -m "Start"

# A VS Code workspace naming the product's repos, and a worktree for a hotfix.
cat > "$ROOT/Harbor/Harbor.code-workspace" <<JSON
{ "folders": [ { "path": "harbor-web" }, { "path": "harbor-api" }, { "path": "harbor-docs" }, { "path": "harbor-ios" }, { "path": "harbor-site" } ] }
JSON
g "$W" worktree add -q "$ROOT/Harbor/harbor-web-hotfix" -b hotfix/rounding main 2>/dev/null
echo "export const fix = 1" >> "$ROOT/Harbor/harbor-web-hotfix/src/lib/cart/total.ts"

rm -rf "$ROOT/.other-docs"
echo "Demo fleet ready: $ROOT (roots: $ROOT/Harbor:$ROOT/Atlas:$ROOT/Personal)"
