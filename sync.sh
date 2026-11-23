#!/usr/bin/env bash
# Sync this pruned fork of mattpocock/skills and refresh the host's skill links.
#
# Usage:
#   ./sync.sh                          Fetch upstream, show what changed, relink for OpenCode. No merge.
#   ./sync.sh --target hermes          Same, but install the Hermes keep list (planning subset).
#   ./sync.sh --merge                  Also merge upstream/main, keeping our skill deletions.
#   ./sync.sh --target hermes --copy   Copy instead of symlink (for hosts that do not follow links).
#
# --target opencode (the default) links skills.keep into ~/.agents/skills and
# regenerates OpenCode slash command wrappers for disable-model-invocation skills.
# --target hermes links skills.keep.hermes into <hermes skills dir>/mattpocock/<name>,
# skips all OpenCode wrapper logic, and refuses to overwrite a name Hermes already has.
# Any target stops on a dirty working tree, so edits made through the links are seen.

set -euo pipefail
export LC_ALL=C  # stable sort order for comm

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK_DIR="${AGENT_SKILLS_LINK_DIR:-$HOME/.agents/skills}"
CMD_DIR="${OPENCODE_COMMANDS_DIR:-$HOME/.config/opencode/commands}"
KEEP_FILE="$REPO/skills.keep"
UPSTREAM_REF="upstream/main"

# Hermes target: HERMES_HOME mirrors what Hermes itself resolves (default ~/.hermes).
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
HERMES_SKILLS_DIR="${HERMES_SKILLS_DIR:-$HERMES_HOME_DIR/skills}"
HERMES_KEEP_FILE="$REPO/skills.keep.hermes"
HERMES_LINK_DIR="$HERMES_SKILLS_DIR/mattpocock"

TARGET="opencode"
MERGE=0
COPY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || { echo "--target needs a value (opencode|hermes)" >&2; exit 2; }
      TARGET="$2"; shift 2 ;;
    --target=*)
      TARGET="${1#--target=}"; shift ;;
    --merge) MERGE=1; shift ;;
    --copy) COPY=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$TARGET" in
  opencode|hermes) ;;
  *) echo "Unknown target: $TARGET (expected opencode or hermes)" >&2; exit 2 ;;
esac

cd "$REPO"

keep_list() {
  grep -vE '^\s*(#|$)' "$1" | sed 's/[[:space:]]//g' | sort -u
}

# Skill directories (those with a SKILL.md) under skills/, as repo-relative paths.
skill_dirs() {
  find skills -mindepth 3 -maxdepth 3 -name SKILL.md -printf '%h\n' | sort
}

skill_dir_for() {
  skill_dirs | awk -F/ -v n="$1" '$NF == n' | head -n1
}

keep_file_for_target() {
  if [[ "$TARGET" == "hermes" ]]; then echo "$HERMES_KEEP_FILE"; else echo "$KEEP_FILE"; fi
}

# A dirty tree means someone (usually Hermes, through a link) changed a kept
# skill. Stop before touching anything and show it.
require_clean_tree() {
  local dirty
  dirty="$(git status --porcelain)"
  if [[ -n "$dirty" ]]; then
    echo "Working tree is dirty. Commit or stash the changes first." >&2
    echo "Nothing was relinked. git status:" >&2
    git --no-pager status --short >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- opencode

link_skills() {
  mkdir -p "$LINK_DIR"
  local keep dir name target
  keep="$(keep_list "$KEEP_FILE")"

  echo "== Linking kept skills into $LINK_DIR"
  while read -r name; do
    dir="$(skill_dir_for "$name")"
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
  keep="$(keep_list "$KEEP_FILE")"
  mkdir -p "$CMD_DIR"

  echo "== Command wrappers for user-invoked skills in $CMD_DIR"
  while read -r name; do
    dir="$(skill_dir_for "$name")"
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

# ---------------------------------------------------------------- hermes

# Every skill name Hermes already resolves, excluding our own namespace.
# Matches the directory name AND the frontmatter name, because Hermes resolves
# both and refuses same-tier duplicates.
hermes_existing_names() {
  local f n
  find "$HERMES_SKILLS_DIR" -name SKILL.md \
    -not -path "$HERMES_LINK_DIR/*" \
    -not -path '*/.archive/*' \
    -not -path '*/.curator_backups/*' \
    -not -path '*/.hermes-dist/*' \
    -print0 2>/dev/null | while IFS= read -r -d '' f; do
      basename "$(dirname "$f")"
      n="$(awk 'NR == 1 && /^---$/ {f = 1; next} f && /^---$/ {exit} f && /^name:/ {sub(/^name:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit}' "$f" || true)"
      [[ -n "$n" ]] && echo "$n"
    done | sort -u
}

hermes_cleanup() {
  local link dest removed=0
  [[ -d "$HERMES_LINK_DIR" ]] || return 0
  echo "== Removing dangling links that point into $REPO"
  for link in "$HERMES_LINK_DIR"/* "$HERMES_LINK_DIR"/.*; do
    [[ -e "$link" || -L "$link" ]] || continue
    [[ -L "$link" ]] || continue
    dest="$(readlink "$link")"
    [[ "$dest" == "$REPO/"* ]] || continue
    if [[ ! -e "$link" ]]; then
      rm "$link"
      echo "  removed  $(basename "$link") (pointed to ${dest#"$REPO/"})"
      removed=1
    fi
  done
  [[ "$removed" == 1 ]] || echo "  none"
}

# Copy mode: never lose a Hermes self-edit silently. Show the diff first.
hermes_copy_skill() {
  local name="$1" src="$2" dest="$HERMES_LINK_DIR/$name"
  if [[ -L "$dest" ]]; then
    rm "$dest"
  fi
  if [[ -d "$dest" ]]; then
    if ! diff -rq "$src" "$dest" >/dev/null 2>&1; then
      echo "  DIFF     $name: the Hermes copy differs from the fork; about to replace it:"
      diff -ru "$src" "$dest" | sed 's/^/    /' || true
    fi
  fi
  rsync -a --delete "$src/" "$dest/"
}

hermes_install() {
  local keep existing name dir target dest collisions=0
  keep="$(keep_list "$HERMES_KEEP_FILE")"
  if [[ -z "$keep" ]]; then
    echo "skills.keep.hermes is empty; nothing to install." >&2
    exit 1
  fi
  mkdir -p "$HERMES_LINK_DIR"

  echo "== Hermes skills dir: $HERMES_SKILLS_DIR"
  echo "== Checking kept names against skills Hermes already has"
  existing="$(hermes_existing_names)"

  if [[ "$COPY" == 1 ]]; then
    echo "== Copying kept skills into $HERMES_LINK_DIR"
  else
    echo "== Linking kept skills into $HERMES_LINK_DIR"
  fi

  while read -r name; do
    dir="$(skill_dir_for "$name")"
    if [[ -z "$dir" ]]; then
      echo "  MISSING  $name (in skills.keep.hermes but not in the fork)"
      continue
    fi
    if grep -qxF "$name" <<< "$existing"; then
      echo "  SKIP     $name (Hermes already has a skill by that name outside mattpocock/)"
      collisions=$((collisions + 1))
      continue
    fi
    target="$REPO/$dir"
    dest="$HERMES_LINK_DIR/$name"

    if [[ "$COPY" == 1 ]]; then
      hermes_copy_skill "$name" "$target"
      echo "  copied   $name -> $dir"
      continue
    fi

    if [[ -d "$dest" && ! -L "$dest" ]]; then
      echo "  SKIP     $name (a real directory sits at $dest, not our link; rerun with --copy)"
      continue
    fi
    if [[ -L "$dest" && "$(readlink "$dest")" != "$REPO/"* ]]; then
      echo "  SKIP     $name (link points outside $REPO)"
      continue
    fi
    ln -sfn "$target" "$dest"
    echo "  linked   $name -> $dir"
  done <<< "$keep"

  hermes_cleanup

  if [[ "$collisions" -gt 0 ]]; then
    echo "  $collisions kept skill(s) skipped on a name collision; resolve by renaming or by"
    echo "  adding the name to skills.disabled in ~/.hermes/config.yaml."
  fi
}

report_unkept() {
  local keep_file="$1" keep dir name found=0
  keep="$(keep_list "$keep_file")"
  echo "== Skill folders in the fork that are not in $(basename "$keep_file") (not linked)"
  while read -r dir; do
    [[ -n "$dir" ]] || continue
    name="$(basename "$dir")"
    if ! grep -qxF "$name" <<< "$keep"; then
      echo "  $dir"
      found=1
    fi
  done <<< "$(skill_dirs)"
  if [[ "$found" == 1 ]]; then
    echo "  To keep one, add its name to $(basename "$keep_file") and rerun ./sync.sh --target $TARGET."
    echo "  To drop one, git rm -r it and commit."
  else
    echo "  none"
  fi
}

install_target() {
  if [[ "$TARGET" == "hermes" ]]; then
    hermes_install
  else
    link_skills
  fi
}

# ---------------------------------------------------------------- main

echo "== Fetching upstream"
git fetch --quiet upstream

require_clean_tree

BASE="$(git merge-base HEAD "$UPSTREAM_REF")"
if [[ "$(git rev-parse "$UPSTREAM_REF")" == "$BASE" ]]; then
  echo "Upstream has nothing new since the last merge ($(git rev-parse --short "$BASE"))."
  install_target
  exit 0
fi

echo "== Upstream commits since last merge ($(git rev-parse --short "$BASE"))"
git --no-pager log --oneline --no-decorate "$BASE..$UPSTREAM_REF"
echo
echo "== Upstream diffstat since last merge"
git --no-pager diff --stat "$BASE" "$UPSTREAM_REF"
echo

if [[ "$MERGE" == 0 ]]; then
  install_target
  echo
  echo "No merge done. Run ./sync.sh --merge to merge $UPSTREAM_REF."
  exit 0
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

install_target
echo

echo "== Skill folders that are new upstream in this merge"
NEW="$(comm -13 <(echo "$PRE_MERGE_SKILLS") \
  <(git ls-tree -r --name-only HEAD -- skills | grep '/SKILL.md$' | xargs -r -n1 dirname | sort -u))"
if [[ -n "$NEW" ]]; then
  sed 's/^/  /' <<< "$NEW"
  echo "  Not linked. Add a name to $(basename "$(keep_file_for_target)") to link it, or git rm -r the folder to drop it."
else
  echo "  none"
fi
echo
report_unkept "$(keep_file_for_target)"
echo
echo "Merge is local. Push with: git push origin main"
