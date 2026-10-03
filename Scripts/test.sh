#!/bin/bash
# Runs the unit tests for the core library (Jira client, board logic, AI parsing).
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh
JIRABAR_CORE_ONLY=1 swift test "$@"
