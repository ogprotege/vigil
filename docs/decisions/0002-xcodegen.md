# ADR-0002: XcodeGen instead of a checked-in .xcodeproj

**Status:** accepted

## Decision

`apps/apple/project.yml` (XcodeGen manifest) is the source of truth; `Vigil.xcodeproj` is generated on the Mac (`brew install xcodegen && xcodegen generate`) and gitignored.

## Context

This project is partly authored from Linux environments where Xcode does not exist. `project.pbxproj` is difficult to author or review blind, while a declarative YAML manifest is diffable and editable anywhere. Apple CI regenerates the project, builds the iOS Simulator destination, and runs the app reliability suite against macOS on every push. Device-only behavior remains a required release check.

## Consequences

- One extra dev-machine prerequisite (xcodegen via Homebrew). End users are unaffected.
- Target/entitlement changes are reviewable in plain YAML.
