#!/usr/bin/env bash
# Rewrites the project list in README.md, between the two marker comments,
# from the account's public repositories on GitHub: every repository that is
# not a fork, not archived and not this profile repository, the most recently
# changed first, with its description and its latest release.
#
#   scripts/update-projects.sh [account]
#
# GITHUB_TOKEN is optional: it raises the API limit from 60 to 5,000 requests
# an hour. Needs curl and jq.
set -euo pipefail

account="${1:-${GITHUB_REPOSITORY_OWNER:-zxxdev}}"
readme="${README:-README.md}"
start='<!-- projects:start -->'
end='<!-- projects:end -->'

api() {
  local auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
  curl --fail --silent --show-error --max-time 10 \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
    "${auth[@]}" "https://api.github.com/$1"
}

grep -qF "$start" "$readme" && grep -qF "$end" "$readme" || {
  echo "$readme has no $start ... $end block" >&2
  exit 1
}

repositories=$(api "users/$account/repos?type=owner&sort=pushed&per_page=100" | jq -c --arg account "$account" '
  [.[] | select((.fork | not) and (.archived | not) and ((.name | ascii_downcase) != ($account | ascii_downcase)))]
  | .[] | {name, url: (if (.homepage // "") | startswith("https://") then .homepage else .html_url end), description: (.description // "")}')

list=$(mktemp)
trap 'rm -f "$list"' EXIT
while IFS= read -r repository; do
  [ -n "$repository" ] || continue
  name=$(jq -r .name <<<"$repository")
  url=$(jq -r .url <<<"$repository")
  description=$(jq -r .description <<<"$repository")
  # A repository with no release answers 404; that is not an error.
  release=$(api "repos/$account/$name/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' || true)
  line="- **[$name]($url)**"
  [ -n "$description" ] && line="$line: $description"
  [ -n "$release" ] && line="$line *Latest release: $release.*"
  printf '%s\n' "$line" >>"$list"
done <<<"$repositories"

[ -s "$list" ] || {
  echo "No repositories found for $account: leaving $readme as it is." >&2
  exit 1
}

# Everything outside the markers is kept as it is.
awk -v start="$start" -v end="$end" -v list="$list" '
  index($0, start) == 1 { print; while ((getline line < list) > 0) print line; skipping = 1; next }
  index($0, end) == 1 { skipping = 0 }
  !skipping
' "$readme" >"$readme.new"
mv "$readme.new" "$readme"
echo "Listed $(wc -l <"$list") repositories."
