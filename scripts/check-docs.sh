#!/bin/sh
set -eu

VIGIL_DOC_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$VIGIL_DOC_ROOT"

VIGIL_CURRENT_DOCS='README.md
SECURITY.md
CLAUDE.md
docs/index.md
docs/product-contract.md
docs/documentation-health.md
docs/threat-model.md
docs/decisions/README.md
docs/release.md
docs/releases/0.15.0-21.md
docs/user-guide/setup.md
docs/user-guide/reading-limits.md
docs/user-guide/history-and-imports.md
docs/user-guide/privacy-deletion-notifications.md
docs/user-guide/troubleshooting.md
docs/user-guide/provider-changes.md
docs/providers/support-matrix.md
docs/providers/provider-details.md
docs/providers/unsupported-candidates.md
docs/development/architecture.md
docs/development/development.md
docs/development/testing.md
docs/development/provider-contribution.md
docs/development/diagnostic-schema.md
docs/development/release.md
dev/archive/README.md
dev/releases/0.15.0-21/README.md'

printf '%s\n' "$VIGIL_CURRENT_DOCS" | while IFS= read -r VIGIL_DOC_PATH; do
  if test ! -f "$VIGIL_DOC_PATH"; then
    echo "$VIGIL_DOC_PATH: required current document is missing" >&2
    exit 1
  fi
  if ! grep -qi 'Last reviewed:' "$VIGIL_DOC_PATH"; then
    echo "$VIGIL_DOC_PATH: missing Last reviewed metadata" >&2
    exit 1
  fi
  if ! grep -qi 'Review again:' "$VIGIL_DOC_PATH"; then
    echo "$VIGIL_DOC_PATH: missing Review again metadata" >&2
    exit 1
  fi
done

VIGIL_MARKDOWN_LIST=$(mktemp)
trap 'rm -f "$VIGIL_MARKDOWN_LIST"' EXIT HUP INT TERM
git ls-files --cached --others --exclude-standard -- '*.md' > "$VIGIL_MARKDOWN_LIST"

ruby - "$VIGIL_MARKDOWN_LIST" <<'RUBY'
require "pathname"
require "uri"

root = Pathname.pwd
files = File.readlines(ARGV.fetch(0), chomp: true)
errors = []

files.each do |relative|
  path = root.join(relative)
  next unless path.file?

  text = path.read
  fences = text.each_line.count { |line| line.match?(/^\s*```/) }
  errors << "#{relative}: unbalanced fenced code block" if fences.odd?

  text.scan(/!?\[[^\]]*\]\(([^)]+)\)/).flatten.each do |raw_target|
    target = raw_target.strip
    target = target[1...-1] if target.start_with?("<") && target.end_with?(">")
    next if target.empty? || target.start_with?("#")
    next if target.match?(/\A(?:https?|mailto):/i)

    file_part = target.split("#", 2).first
    file_part = URI::DEFAULT_PARSER.unescape(file_part)
    resolved = path.dirname.join(file_part).cleanpath
    errors << "#{relative}: missing local link target #{raw_target}" unless resolved.exist?
  end
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end
RUBY

ruby <<'RUBY'
require "pathname"
require "uri"

root = Pathname.pwd
compatibility = %w[
  docs/architecture.md
  docs/provider-spec.md
  docs/provider-contribution.md
  docs/release.md
].to_h { |path| [root.join(path).cleanpath.to_s, path] }
sources = ["README.md", "SECURITY.md", "CLAUDE.md", "docs/index.md", "docs/product-contract.md"]
sources.concat(Dir["docs/{user-guide,providers,development}/**/*.md"])
errors = []

sources.each do |relative|
  path = root.join(relative)
  next unless path.file?

  path.read.scan(/!?\[[^\]]*\]\(([^)]+)\)/).flatten.each do |raw_target|
    target = raw_target.strip
    target = target[1...-1] if target.start_with?("<") && target.end_with?(">")
    next if target.empty? || target.start_with?("#")
    next if target.match?(/\A(?:https?|mailto):/i)

    file_part = URI::DEFAULT_PARSER.unescape(target.split("#", 2).first)
    resolved = path.dirname.join(file_part).cleanpath.to_s
    next unless compatibility.key?(resolved)

    errors << "#{relative}: current documentation links through compatibility path #{compatibility.fetch(resolved)}"
  end
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end
RUBY

if printf '%s\n' "$VIGIL_CURRENT_DOCS" \
  | xargs grep -En 'Status: proposed|Proposed current|TODO|TBD'; then
  echo 'Current documentation contains proposal or placeholder text.' >&2
  exit 1
fi

VIGIL_DOC_VERSION=$(awk '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' apps/apple/project.yml)
VIGIL_DOC_BUILD=$(awk '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { print $2; exit }' apps/apple/project.yml)
test -n "$VIGIL_DOC_VERSION"
test -n "$VIGIL_DOC_BUILD"
test -f "docs/releases/$VIGIL_DOC_VERSION-$VIGIL_DOC_BUILD.md"
grep -Fq "Vigil $VIGIL_DOC_VERSION, build $VIGIL_DOC_BUILD" README.md
grep -Fq "## $VIGIL_DOC_VERSION ($VIGIL_DOC_BUILD)" CHANGELOG.md

echo "Documentation checks passed for Vigil $VIGIL_DOC_VERSION ($VIGIL_DOC_BUILD)."
