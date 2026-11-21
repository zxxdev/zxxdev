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

# The latest release's tag, or nothing when the repository has none (404).
# Any other failure (rate limit, server error) stops the script, so a passing
# GitHub problem never commits a list with releases missing.
latest_release() {
  local auth=() body status
  if [ -n "${GITHUB_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
  body=$(mktemp)
  status=$(curl --silent --show-error --max-time 10 -o "$body" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
    "${auth[@]}" "https://api.github.com/repos/$account/$1/releases/latest")
  case "$status" in
    200) jq -r '.tag_name // empty' "$body" ;;
    404) ;;
    *)
      echo "Release of $1: HTTP $status" >&2
      rm -f "$body"
      return 1
      ;;
  esac
  rm -f "$body"
}

# Characters that would change the Markdown around a description, escaped.
escape_markdown() {
  sed -e 's/[][\\`*_<>()#|]/\\&/g'
}

start_line=$(grep -nF "$start" "$readme" | head -1 | cut -d: -f1)
end_line=$(grep -nF "$end" "$readme" | head -1 | cut -d: -f1)
if [ -z "$start_line" ] || [ -z "$end_line" ] || [ "$start_line" -ge "$end_line" ]; then
  echo "$readme needs $start and then $end, in that order" >&2
  exit 1
fi

repositories=$(api "users/$account/repos?type=owner&sort=pushed&per_page=100" | jq -c --arg account "$account" '
  [.[] | select((.fork | not) and (.archived | not) and ((.name | ascii_downcase) != ($account | ascii_downcase)))]
  | .[] | {
      name,
      # A homepage is used only if it is a plain https address that cannot break the link.
      url: (if ((.homepage // "") | test("^https://[^\\s()<>\\[\\]]+$")) then .homepage else .html_url end),
      description: (.description // "")
    }')

list=$(mktemp)
trap 'rm -f "$list"' EXIT
while IFS= read -r repository; do
  [ -n "$repository" ] || continue
  name=$(jq -r .name <<<"$repository")
  url=$(jq -r .url <<<"$repository")
  description=$(jq -r .description <<<"$repository" | escape_markdown)
  release=$(latest_release "$name" | escape_markdown)
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
