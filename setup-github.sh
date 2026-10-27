#!/usr/bin/env bash
#
# Builds the TruWood Q4 tracker in GitHub: labels, milestones, 87 issues,
# and a Project with a Due date field so the Roadmap view works.
#
#   ./setup-github.sh <owner>/<repo>
#
# Safe to re-run. It records what it created in .q4-state.json next to itself
# and skips anything already there, so if it stops halfway, run it again.
#
# Requires: gh (GitHub CLI, logged in), jq.
# The Project steps need extra scopes:  gh auth refresh -s project,read:project
#
set -euo pipefail

REPO="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$HERE/truwood-q4-github.json"
STATE="$HERE/.q4-state.json"
export GH_PAGER=cat

die() { printf '\n  %s\n\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }

[ -n "$REPO" ] || die "Usage: ./setup-github.sh <owner>/<repo>    e.g. ./setup-github.sh nolanmaldonado/truwood-q4"
case "$REPO" in */*) ;; *) die "Repo must be owner/repo, not just a name." ;; esac
OWNER="${REPO%%/*}"

command -v gh >/dev/null || die "GitHub CLI not found. Install it: https://cli.github.com"
command -v jq >/dev/null || die "jq not found. brew install jq"
[ -f "$DATA" ] || die "Can't find truwood-q4-github.json next to this script."
gh auth status >/dev/null 2>&1 || die "Not logged in. Run: gh auth login"

[ -f "$STATE" ] || echo '{"issues":{},"items":{}}' > "$STATE"
state_get() { jq -r --arg k "$2" ".$1[\$k] // empty" "$STATE"; }
state_put() { local tmp; tmp="$(mktemp)"; jq --arg k "$2" --arg v "$3" ".$1[\$k]=\$v" "$STATE" > "$tmp" && mv "$tmp" "$STATE"; }

# Stable key per task title. shasum on macOS, sha1sum on Linux.
if command -v shasum >/dev/null; then HASH() { shasum; }
elif command -v sha1sum >/dev/null; then HASH() { sha1sum; }
else HASH() { cksum; }; fi
keyof() { printf '%s' "$1" | HASH | cut -c1-12; }

# ---------------------------------------------------------------- 1. repo
step "1/6  Repository"
if gh repo view "$REPO" >/dev/null 2>&1; then
  say "$REPO already exists, using it."
else
  say "Creating $REPO (private)..."
  gh repo create "$REPO" --private --description "TruWood Q4 2026 campaign execution tracker" >/dev/null
  say "Created."
fi

# -------------------------------------------------------------- 2. labels
step "2/6  Labels"
jq -c '.labels[]' "$DATA" | while read -r l; do
  name=$(jq -r '.name' <<<"$l")
  if gh api "repos/$REPO/labels/$(jq -rn --arg s "$name" '$s|@uri')" >/dev/null 2>&1; then
    say "= $name"
  else
    gh api -X POST "repos/$REPO/labels" \
      -f name="$name" -f color="$(jq -r '.color' <<<"$l")" \
      -f description="$(jq -r '.description' <<<"$l")" >/dev/null
    say "+ $name"
  fi
done

# ---------------------------------------------------------- 3. milestones
step "3/6  Milestones (one per campaign phase)"
existing=$(gh api --paginate "repos/$REPO/milestones?state=all" | jq -s 'add // []')
jq -c '.milestones[]' "$DATA" | while read -r m; do
  title=$(jq -r '.title' <<<"$m")
  num=$(jq -r --arg t "$title" '.[] | select(.title==$t) | .number' <<<"$existing" | head -1)
  if [ -n "$num" ]; then
    say "= $title (#$num)"
  else
    num=$(gh api -X POST "repos/$REPO/milestones" \
      -f title="$title" -f due_on="$(jq -r '.due_on' <<<"$m")" \
      -f description="$(jq -r '.description' <<<"$m")" | jq -r '.number')
    say "+ $title (#$num)"
  fi
done

# ------------------------------------------------------------- 4. issues
step "4/6  Issues (87 of them, about two minutes)"
ms_map=$(gh api --paginate "repos/$REPO/milestones?state=all" | jq -s 'add // []' \
         | jq 'map({(.title): .number}) | add // {}')

total=$(jq '.issues | length' "$DATA")
i=0
while read -r iss; do
  i=$((i+1))
  title=$(jq -r '.title' <<<"$iss")
  key=$(keyof "$title")
  if [ -n "$(state_get issues "$key")" ]; then
    printf '  [%2d/%d] = already created\n' "$i" "$total"
    continue
  fi
  msname=$(jq -r '.milestone' <<<"$iss")
  msnum=$(jq -r --arg t "$msname" '.[$t] // empty' <<<"$ms_map")
  labels=$(jq -r '.labels | join(",")' <<<"$iss")

  args=(-X POST "repos/$REPO/issues"
        -f title="$title"
        -f body="$(jq -r '.body' <<<"$iss")")
  [ -n "$msnum" ] && args+=(-F milestone="$msnum")
  IFS=',' read -ra L <<< "$labels"
  for lab in "${L[@]}"; do args+=(-f "labels[]=$lab"); done

  url=$(gh api "${args[@]}" | jq -r '.html_url')
  state_put issues "$key" "$url"
  printf '  [%2d/%d] + %s\n' "$i" "$total" "${title:0:58}"
  sleep 1          # stay under GitHub's content-creation rate limit
done < <(jq -c '.issues[]' "$DATA")

# ------------------------------------------------------------ 5. project
step "5/6  Project + Due date field"
if ! gh project list --owner "$OWNER" >/dev/null 2>&1; then
  die "The Project API needs more scopes. Run this, then re-run the script:

     gh auth refresh -s project,read:project

   Issues and milestones are already created, so it will pick up where it left off."
fi

PTITLE=$(jq -r '.project_title' "$DATA")
PNUM=$(gh project list --owner "$OWNER" --format json \
       | jq -r --arg t "$PTITLE" '.projects[] | select(.title==$t) | .number' | head -1)
if [ -z "$PNUM" ]; then
  PNUM=$(gh project create --owner "$OWNER" --title "$PTITLE" --format json | jq -r '.number')
  say "+ Project #$PNUM \"$PTITLE\""
else
  say "= Project #$PNUM \"$PTITLE\""
fi
PID=$(gh project view "$PNUM" --owner "$OWNER" --format json | jq -r '.id')

FIELDS=$(gh project field-list "$PNUM" --owner "$OWNER" --format json)
DUE_ID=$(jq -r '.fields[] | select(.name=="Due") | .id' <<<"$FIELDS")
if [ -z "$DUE_ID" ] || [ "$DUE_ID" = "null" ]; then
  DUE_ID=$(gh project field-create "$PNUM" --owner "$OWNER" --name "Due" \
           --data-type DATE --format json | jq -r '.id')
  say "+ Due (date field)"
else
  say "= Due (date field)"
fi

# --------------------------------------------------- 6. items + due dates
step "6/6  Adding issues to the project and setting their dates"
i=0
while read -r iss; do
  i=$((i+1))
  title=$(jq -r '.title' <<<"$iss")
  key=$(keyof "$title")
  url=$(state_get issues "$key")
  [ -n "$url" ] || { printf '  [%2d/%d] ! no issue url, skipping\n' "$i" "$total"; continue; }

  item=$(state_get items "$key")
  if [ -z "$item" ]; then
    item=$(gh project item-add "$PNUM" --owner "$OWNER" --url "$url" --format json | jq -r '.id')
    state_put items "$key" "$item"
  fi
  gh project item-edit --id "$item" --project-id "$PID" \
     --field-id "$DUE_ID" --date "$(jq -r '.due' <<<"$iss")" >/dev/null
  printf '  [%2d/%d] %s\n' "$i" "$total" "${title:0:58}"
  sleep 0.4
done < <(jq -c '.issues[]' "$DATA")

cat <<EOF

Done.

  Issues     https://github.com/$REPO/issues
  Project    https://github.com/users/$OWNER/projects/$PNUM
             (if that 404s, it is an org project: /orgs/$OWNER/projects/$PNUM)

Two things to finish in the browser — GitHub has no API for creating Project
views, so these are clicks, not script:

  1. ROADMAP (the Gantt). In the Project, click the + beside the view tabs,
     choose Roadmap, then in its settings set both Start and Target to "Due".
     Group by Milestone to get the phases as bands.

  2. BOARD (the Kanban). Click + again, choose Board, group by Status.
     Then select all items in the Table view and set Status to Todo in one
     go — new items arrive with no status and would otherwise pile into a
     "No Status" column.

EOF
