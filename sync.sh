#!/usr/bin/env bash
# Sync this pruned fork of mattpocock/skills and refresh the OpenCode skill links.
#
# Usage:
#   ./sync.sh           Fetch upstream, show what changed since the last merge, relink. No merge.
#   ./sync.sh --merge   Also merge upstream/main, keeping our skill deletions.
#
# Only skills named in skills.keep are linked into ~/.agents/skills.
# Kept skills marked disable-model-invocation also get an OpenCode slash
# command wrapper in ~/.config/opencode/commands, regenerated on every run.

set -euo pipefail
export LC_ALL=C  # stable sort order for comm

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK_DIR="${AGENT_SKILLS_LINK_DIR:-$HOME/.agents/skills}"
CMD_DIR="${OPENCODE_COMMANDS_DIR:-$HOME/.config/opencode/commands}"
KEEP_FILE="$REPO/skills.keep"
UPSTREAM_REF="upstream/main"

MERGE=0
case "${1:-}" in
  "") ;;
  --merge) MERGE=1 ;;
  -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

cd "$REPO"

keep_list() {
  grep -vE '^\s*(#|$)' "$KEEP_FILE" | sed 's/[[:space:]]//g' | sort -u
}

# Skill directories (those with a SKILL.md) under skills/, as repo-relative paths.
skill_dirs() {
  find skills -mindepth 3 -maxdepth 3 -name SKILL.md -printf '%h\n' | sort
}

link_skills() {
  mkdir -p "$LINK_DIR"
  local keep dir name target
  keep="$(keep_list)"

  echo "== Linking kept skills into $LINK_DIR"
  while read -r name; do
    dir="$(skill_dirs | awk -F/ -v n="$name" '$NF == n' | head -n1)"
    if [[ -z "$dir" ]]; then
      echo "  MISSING  $name (in skills.keep but not in the fork)"
      continue
    fi
    target="$REPO/$dir"
    if [[ -e "$LINK_DIR/$name" || -L "$LINK_DIR/$name" ]]; then
      if [[ ! -L "$LINK_DIR/$name" || "$(readlink "$LINK_DIR/$name")" != "$REPO/"* ]]; then
        echo "  SKIP     $name (exists and is not one of our links)"
        continue
      fi
    fi
    ln -sfn "$target" "$LINK_DIR/$name"
    echo "  linked   $name -> $dir"
  done <<< "$keep"

  echo "== Removing dangling links that point into $REPO"
  local link dest removed=0
  for link in "$LINK_DIR"/*; do
    [[ -L "$link" ]] || continue
    dest="$(readlink "$link")"
    [[ "$dest" == "$REPO/"* ]] || continue
    if [[ ! -e "$link" ]]; then
      rm "$link"
      echo "  removed  $(basename "$link") (pointed to ${dest#"$REPO/"})"
      removed=1
    elif ! grep -qxF "$(basename "$link")" <<< "$keep"; then
      echo "  NOTE     $(basename "$link") is linked but not in skills.keep (left alone)"
    fi
  done
  [[ "$removed" == 1 ]] || echo "  none"

  sync_commands
}

# The body line every generated command wrapper carries. It is also how we
# recognize a wrapper as ours, so files written by hand are never touched.
wrapper_body() {
  echo "Read ~/.agents/skills/$1/SKILL.md, including any files it references relative to its folder, and follow it exactly. Input: \$ARGUMENTS"
}

is_our_wrapper() {
  local file="$1" name
  name="$(basename "$file" .md)"
  grep -qxF -- "$(wrapper_body "$name")" "$file"
}

# Print a SKILL.md frontmatter block (between the first two --- lines).
frontmatter() {
  awk 'NR == 1 && /^---$/ {f = 1; next} f && /^---$/ {exit} f' "$1"
}

# OpenCode hides user-invoked-only skills from the model, so they get a
# slash command wrapper in OpenCode's global commands folder.
sync_commands() {
  local keep name dir fm desc file tmp wanted=""
  keep="$(keep_list)"
  mkdir -p "$CMD_DIR"

  echo "== Command wrappers for user-invoked skills in $CMD_DIR"
  while read -r name; do
    dir="$(skill_dirs | awk -F/ -v n="$name" '$NF == n' | head -n1)"
    [[ -n "$dir" ]] || continue
    fm="$(frontmatter "$REPO/$dir/SKILL.md")"
    grep -qE '^disable-model-invocation:[[:space:]]*true[[:space:]]*$' <<< "$fm" || continue
    # Copy the description line as written, so its YAML quoting stays valid.
    desc="$(grep -m1 '^description:' <<< "$fm" || true)"
    if [[ -z "$desc" ]]; then
      echo "  SKIP     $name (no description in frontmatter)"
      continue
    fi
    wanted+="$name"$'\n'
    file="$CMD_DIR/$name.md"
    if [[ -e "$file" ]] && ! is_our_wrapper "$file"; then
      echo "  SKIP     $name (a command file not made by sync.sh exists)"
      continue
    fi
    tmp="$(mktemp)"
    printf -- '---\n%s\n---\n%s\n' "$desc" "$(wrapper_body "$name")" > "$tmp"
    if [[ -e "$file" ]] && cmp -s "$tmp" "$file"; then
      rm "$tmp"
      echo "  ok       /$name"
    else
      mv "$tmp" "$file"
      chmod 644 "$file"
      echo "  wrote    /$name"
    fi
  done <<< "$keep"

  local removed=0
  for file in "$CMD_DIR"/*.md; do
    [[ -e "$file" ]] || continue
    name="$(basename "$file" .md)"
    is_our_wrapper "$file" || continue
    if ! grep -qxF -- "$name" <<< "$wanted"; then
      rm "$file"
      echo "  removed  /$name (no longer a kept user-invoked skill)"
      removed=1
    fi
  done
  [[ "$removed" == 1 ]] || true
}

report_unkept() {
  local keep dir name found=0
  keep="$(keep_list)"
  echo "== Skill folders in the fork that are not in skills.keep (not linked)"
  while read -r dir; do
    [[ -n "$dir" ]] || continue
    name="$(basename "$dir")"
    if ! grep -qxF "$name" <<< "$keep"; then
      echo "  $dir"
      found=1
    fi
  done <<< "$(skill_dirs)"
  if [[ "$found" == 1 ]]; then
    echo "  To keep one, add its name to skills.keep and rerun ./sync.sh."
    echo "  To drop one, git rm -r it and commit."
  else
    echo "  none"
  fi
}

echo "== Fetching upstream"
git fetch --quiet upstream

BASE="$(git merge-base HEAD "$UPSTREAM_REF")"
if [[ "$(git rev-parse "$UPSTREAM_REF")" == "$BASE" ]]; then
  echo "Upstream has nothing new since the last merge ($(git rev-parse --short "$BASE"))."
  link_skills
  exit 0
fi

echo "== Upstream commits since last merge ($(git rev-parse --short "$BASE"))"
git --no-pager log --oneline --no-decorate "$BASE..$UPSTREAM_REF"
echo
echo "== Upstream diffstat since last merge"
git --no-pager diff --stat "$BASE" "$UPSTREAM_REF"
echo

if [[ "$MERGE" == 0 ]]; then
  link_skills
  echo
  echo "No merge done. Run ./sync.sh --merge to merge $UPSTREAM_REF."
  exit 0
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Working tree has uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

# Skill folders that existed at the merge base but are gone from our branch,
# meaning we deleted them on purpose.
mapfile -t DELETED_BY_US < <(
  comm -23 \
    <(git ls-tree -r --name-only "$BASE" -- skills | grep '/SKILL.md$' | xargs -r -n1 dirname | sort -u) \
    <(git ls-tree -r --name-only HEAD -- skills | grep '/SKILL.md$' | xargs -r -n1 dirname | sort -u)
)
PRE_MERGE_SKILLS="$(git ls-tree -r --name-only HEAD -- skills | grep '/SKILL.md$' | xargs -r -n1 dirname | sort -u)"

echo "== Merging $UPSTREAM_REF"
# --no-commit so that keeping our deletions lands in the same merge commit.
git merge --no-edit --no-commit --no-ff "$UPSTREAM_REF" || true

# Keep our deletion for modify/delete conflicts under skills/ (status DU: deleted by us).
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  echo "  keeping our deletion: $path"
  git rm --quiet -- "$path"
done < <(git status --porcelain=v1 | awk '$1 == "DU" && $2 ~ /^skills\// {print $2}')

# Upstream may add new files inside a folder we deleted, which merges cleanly
# and partly brings that folder back. Remove those too.
for dir in "${DELETED_BY_US[@]}"; do
  if [[ -n "$(git ls-files -- "$dir")" ]]; then
    echo "  keeping our deletion: $dir (upstream added files to it)"
    git rm -r -f --quiet -- "$dir"
  fi
done

CONFLICTS="$(git diff --name-only --diff-filter=U)"
if [[ -n "$CONFLICTS" ]]; then
  echo
  echo "Merge stopped. These conflicts need manual resolution (nothing committed):"
  sed 's/^/  /' <<< "$CONFLICTS"
  echo "Resolve them, then: git add <files> && git commit --no-edit && ./sync.sh"
  echo "Or abort with: git merge --abort"
  exit 1
fi

if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  git commit --quiet --no-edit
  echo "  merge committed: $(git log --oneline -1 --no-decorate)"
else
  echo "  nothing to commit"
fi
echo

link_skills
echo

echo "== Skill folders that are new upstream in this merge"
NEW="$(comm -13 <(echo "$PRE_MERGE_SKILLS") \
  <(git ls-tree -r --name-only HEAD -- skills | grep '/SKILL.md$' | xargs -r -n1 dirname | sort -u))"
if [[ -n "$NEW" ]]; then
  sed 's/^/  /' <<< "$NEW"
  echo "  Not linked. Add a name to skills.keep to link it, or git rm -r the folder to drop it."
else
  echo "  none"
fi
echo
report_unkept
echo
echo "Merge is local. Push with: git push origin main"
