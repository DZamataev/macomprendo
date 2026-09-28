## Operator gate

This card is the operator's. It stays blocked until they answer; no worker ever
completes it. The task below carries:

- the artifacts, as absolute paths;
- one copy-pasteable command that opens them (usually
  `npm run install-app:signed` in the chain's worktree, then the smoke steps);
- numbered questions, answerable by number.

The orchestrator records the verdict and runs
`hermes kanban --board {{BOARD}} complete <this-id> --summary "<verdict>"`.

## Task
