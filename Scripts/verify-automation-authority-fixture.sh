#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
fixture="$repo_root/Shared/Automation/Fixtures/automation-authority-v1.json"
build_dir="$(mktemp -d /private/tmp/lumen-automation-authority.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT

xcrun swiftc \
  -module-cache-path "$build_dir/module-cache" \
  "$repo_root/Tests/AutomationAuthorityFixtureStub.swift" \
  "$repo_root/Shared/Automation/AutomationPolicyAuthority.swift" \
  "$repo_root/Tests/AutomationAuthorityFixtureHarness.swift" \
  -o "$build_dir/automation-authority-fixture-harness"

"$build_dir/automation-authority-fixture-harness" "$fixture"
