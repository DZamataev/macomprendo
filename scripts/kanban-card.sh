#!/usr/bin/env bash
# Create a board card with the role's standing constraints prepended.
#   scripts/kanban-card.sh <impl|research|review|fix|gate> "<title>" <task-file|-> <workdir> [parent-id...]
# Delegates to the hermes-kanban-development skill's kanban-card.sh, which reads
# .kanban/config.env and the gitignored .env.local of the primary checkout, and
# subscribes the card to the Telegram topic and to the desktop/TUI session
# running it. Env: KANBAN_BLOCKED=1, KANBAN_NOTIFY_SESSION=0. Prints the card id.
# Requires Hermes from the develop branch of https://github.com/DZamataev/hermes-agent
# and the skill from https://github.com/DZamataev/hermes-tools (kanban/install.sh).
set -euo pipefail
K="${KANBAN_SKILL_SCRIPTS:-${HERMES_HOME:-$HOME/.hermes}/skills/software-development/hermes-kanban-development/scripts}"
[ -f "$K/kanban-card.sh" ] || {
  echo "hermes-kanban-development skill not installed at $K" >&2
  echo "install it: git clone https://github.com/DZamataev/hermes-tools && bash hermes-tools/kanban/install.sh" >&2
  exit 2
}
KANBAN_REPO="${KANBAN_REPO:-$(cd "$(dirname "$0")/.." && pwd)}" exec bash "$K/kanban-card.sh" "$@"
