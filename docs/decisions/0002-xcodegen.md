# ADR-0002: XcodeGen instead of a checked-in .xcodeproj

**Status:** accepted

## Decision

`apps/apple/project.yml` (XcodeGen manifest) is the source of truth; `Vigil.xcodeproj` is generated on the Mac (`brew install xcodegen && xcodegen generate`) and gitignored.

## Context

This project is partly authored from Linux environments where Xcode doesn't exist. `project.pbxproj` is a hostile format to author or review blind; a declarative YAML manifest is diffable and editable anywhere. The macOS CI workflow runs the same two commands, so every push compile-checks Swift authored off-Mac.

## Consequences

- One extra dev-machine prerequisite (xcodegen via Homebrew). End users are unaffected.
- Target/entitlement changes are reviewable in plain YAML.
