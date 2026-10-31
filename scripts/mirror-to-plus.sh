#!/usr/bin/env bash
# mirror-to-plus.sh — propagate shared container-scaffolding changes from
# claudeclaw-container → a review PR in claudeclaw-plus-container.
#
# The two image repos are byte-identical except for two axes:
#   1. which upstream gets cloned (moazbuilds/claudeclaw vs TerrysPOV/ClaudeClaw-Plus)
#   2. cosmetic "claudeclaw" vs "claudeclaw-plus" naming (log prefixes, volume/
#      service names, the CLAUDECLAW[_PLUS]_BACKUP_DIR env var, etc.)
#
# A blind file copy would clobber both. Instead this script mirrors ONLY the
# shared build/runtime files, applies each change to the plus repo by *context*
# patch (clean hunks in shared regions apply; any hunk that collides with a
# plus-specific line is set aside as a reject and surfaced in the PR for manual
# porting), and opens a PR. Branding review + a local arm64 build happen on
# that PR — the script never auto-merges.
#
# Usage:
#   scripts/mirror-to-plus.sh [BASE_REF] [HEAD_REF]
#     BASE_REF   git ref to diff from   (default: HEAD^, or $BASE_SHA)
#     HEAD_REF   git ref to diff to     (default: HEAD,  or $HEAD_SHA)
#
# Env:
#   PLUS_REPO  target repo   (default: paulmeier/claudeclaw-plus-container)
#   GH_TOKEN   gh/git auth   (CI: the MIRROR_TOKEN fine-grained PAT;
#                             local: your `gh auth` login)
#   DRY_RUN    if non-empty, do everything except `git push` + `gh pr create`
set -euo pipefail

PLUS_REPO="${PLUS_REPO:-paulmeier/claudeclaw-plus-container}"

# Resolve the diff range. CI passes the push event's before/after SHAs; locally
# we default to the last commit. A zero/empty/invalid base (first push, shallow
# clone) falls back to HEAD^.
BASE_REF="${1:-${BASE_SHA:-HEAD^}}"
HEAD_REF="${2:-${HEAD_SHA:-HEAD}}"
if ! git rev-parse --verify -q "${BASE_REF}^{commit}" >/dev/null 2>&1 \
   || [ "$BASE_REF" = "0000000000000000000000000000000000000000" ]; then
  echo "[mirror] base ref '${BASE_REF}' not usable; falling back to HEAD^"
  BASE_REF="HEAD^"
fi

# Shared build/runtime files that are safe to mirror by patch. Branding-heavy or
# repo-specific files are intentionally excluded: README.md, docker-compose.yml,
# SECURITY.md, CLAUDE.md, settings.example.json, LICENSE, the release-please
# config/manifest, CHANGELOG.md, .upstream-ref, icons/, and .github/workflows/*.
ALLOW=(
  Dockerfile
  entrypoint.sh
  backup.sh
  healthcheck.sh
  migrate-python.sh
  migrate-npm.sh
  migrate-pnpm.sh
  migrate-uv.sh
  shell.sh
  .dockerignore
  .hadolint.yaml
)

src_root="$(git rev-parse --show-toplevel)"
short_sha="$(git rev-parse --short "$HEAD_REF")"
full_sha="$(git rev-parse "$HEAD_REF")"

# 1. Which allowlisted files changed in the range?
#    (portable read loop — macOS ships bash 3.2, which lacks `mapfile`)
changed=()
while IFS= read -r f; do [ -n "$f" ] && changed+=("$f"); done \
  < <(git diff --name-only "$BASE_REF" "$HEAD_REF" -- "${ALLOW[@]}")
if [ "${#changed[@]}" -eq 0 ]; then
  echo "[mirror] No shared files changed in ${BASE_REF}..${HEAD_REF}; nothing to mirror."
  exit 0
fi
echo "[mirror] Shared files changed:"
printf '  - %s\n' "${changed[@]}"

# 2. Patch limited to those files.
patch_file="$(mktemp "${TMPDIR:-/tmp}/mirror-patch-XXXXXX")"
git diff "$BASE_REF" "$HEAD_REF" -- "${changed[@]}" > "$patch_file"

# 3. Derive a PR title that preserves the source change's conventional-commit
#    type so the plus repo's release-please cuts the right version. Prefer the
#    head subject; for a merge commit fall back to the merged (second-parent)
#    subject; otherwise label it a chore.
pick_subject() {
  local s; s="$(git -c log.showSignature=false log -1 --format=%s "$1" 2>/dev/null || true)"
  case "$s" in
    feat:*|fix:*|perf:*|refactor:*|feat\(*|fix\(*|perf\(*|refactor\(*) printf '%s' "$s"; return 0;;
  esac
  return 1
}
if subj="$(pick_subject "$HEAD_REF")"; then :
elif subj="$(pick_subject "${HEAD_REF}^2")"; then :
else subj="chore: mirror shared scaffolding from claudeclaw-container"; fi
title="${subj} (mirror @ ${short_sha})"

# 4. Fresh shallow clone of the plus repo (token-auth when provided).
work="$(mktemp -d "${TMPDIR:-/tmp}/mirror-plus-XXXXXX")"
if [ -n "${GH_TOKEN:-}" ]; then
  clone_url="https://x-access-token:${GH_TOKEN}@github.com/${PLUS_REPO}.git"
else
  clone_url="https://github.com/${PLUS_REPO}.git"
fi
git clone --depth 1 "$clone_url" "$work" >/dev/null 2>&1
cd "$work"
branch="mirror/ccc-${short_sha}"
git switch -c "$branch" >/dev/null 2>&1

# 5. Apply by context. --reject (not --3way: the patch's pre-image blobs live in
#    the source repo's object DB, not here) applies clean hunks and writes .rej
#    for any that collide with plus-specific lines.
git apply --reject --whitespace=nowarn "$patch_file" 2>/dev/null \
  && echo "[mirror] Patch applied cleanly." \
  || echo "[mirror] Some hunks collided with plus-specific lines; see rejects."

# Capture, report, and remove any .rej so they don't land in the PR.
rejfiles=()
while IFS= read -r f; do [ -n "$f" ] && rejfiles+=("$f"); done \
  < <(find . -name '*.rej' -type f | sed 's|^\./||' | sort)
rej_report=""
if [ "${#rejfiles[@]}" -gt 0 ]; then
  rej_report=$'\n### ⚠️ Hunks needing manual porting\nThese collided with plus-specific lines (branding / upstream clone) — port them by hand:\n'
  for r in "${rejfiles[@]}"; do
    rej_report+=$'\n<details><summary><code>'"${r%.rej}"$'</code></summary>\n\n```diff\n'"$(cat "$r")"$'\n```\n</details>\n'
    rm -f "$r"
  done
fi

# Nothing applied at all (plus already in parity, or every hunk rejected)?
if git diff --quiet && git diff --cached --quiet; then
  echo "[mirror] No changes applied to plus (already in parity, or all hunks rejected)."
  [ -n "$rej_report" ] && echo "[mirror] (all hunks were rejects — manual port needed)"
  exit 0
fi

applied_list="$(git status --porcelain | sed 's/^/  /')"
git add -A
git -c user.name="claudeclaw mirror" \
    -c user.email="claudeclaw-mirror@users.noreply.github.com" \
    commit -q -m "${title}" -m "Mirrored from claudeclaw-container@${full_sha}. Review branding + build locally before merging."

files_md=""
for f in "${changed[@]}"; do
  files_md="${files_md}${files_md:+$'\n'}* \`${f}\`"
done

body="$(cat <<EOF
Automated mirror of shared container-scaffolding changes from
[\`claudeclaw-container@${short_sha}\`](https://github.com/paulmeier/claudeclaw-container/commit/${full_sha}).

**Files mirrored** (shared build/runtime only — README, compose, workflows, and
release-please files are never mirrored):
${files_md}
${rej_report}
### Before merging
- [ ] Confirm no \`claudeclaw\` → \`claudeclaw-plus\` branding was pulled in (log prefixes, volume/service names, \`CLAUDECLAW_PLUS_BACKUP_DIR\`).
- [ ] Confirm the Dockerfile still clones \`TerrysPOV/ClaudeClaw-Plus\` (not the vanilla upstream).
- [ ] Build + smoke-test locally on \`linux/arm64\`.

🤖 Generated by \`scripts/mirror-to-plus.sh\`
EOF
)"

if [ -n "${DRY_RUN:-}" ]; then
  echo "[mirror] DRY_RUN — would push branch '${branch}' and open a PR titled:"
  echo "         ${title}"
  echo "[mirror] Applied changes:"
  echo "${applied_list}"
  echo "[mirror] --- PR body preview ---"
  echo "${body}"
  exit 0
fi

git push -q -u origin "$branch"
gh pr create --repo "$PLUS_REPO" --base main --head "$branch" \
  --title "$title" --body "$body"
