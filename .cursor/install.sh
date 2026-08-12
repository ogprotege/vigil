#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap for Vigil.
#
# Vigil's Swift package (VigilKit) and iOS app require a macOS + Xcode host and
# are validated by the macOS `apple` CI workflow. On the Linux Cloud Agent the
# runnable development surface is the documentation/protocol gate that CI runs
# first (scripts/check-docs.sh) plus source editing. That gate needs Ruby, so
# this script makes sure Ruby and the other shell tools it relies on are present.
set -euo pipefail

need_pkg=()
command -v ruby >/dev/null 2>&1 || need_pkg+=(ruby)
command -v git  >/dev/null 2>&1 || need_pkg+=(git)
command -v curl >/dev/null 2>&1 || need_pkg+=(curl)
command -v jq   >/dev/null 2>&1 || need_pkg+=(jq)

if [ "${#need_pkg[@]}" -gt 0 ]; then
  echo "Installing missing packages: ${need_pkg[*]}"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends "${need_pkg[@]}"
else
  echo "All required packages already present; nothing to install."
fi

echo "Tool versions:"
ruby --version
git --version
curl --version | head -n 1
jq --version

echo "Vigil Cloud Agent bootstrap complete."
