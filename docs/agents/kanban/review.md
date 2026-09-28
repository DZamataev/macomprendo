## Standing constraints for the reviewer (read first)

- Change nothing in the tree (`{{WORKDIR}}`). Read only; no commits.
- **Do not read:** the ticket, spec or plan the change was written against,
  `{{TEMPLATES}}/tasks/`, the implementation card's body, other cards' comments.
  Reconstruct the intent from the diff. You may read `{{RULES}}`, `docs/adr/` and
  `docs/ARCHITECTURE.md`: they are the rules the diff must obey.
- **Range:** the parent card's summary opens with `START_HEAD..END_HEAD`
  (`hermes kanban --board {{BOARD}} show <parent-id>`). If it is missing, review
  `{{BASE}}..HEAD`. **State in your findings the range you actually reviewed.**
- Run `{{GATE}}` yourself (its last line must contain `{{GATE_OK}}`), plus
  `npm run test:scripts` when the diff touches `scripts/`. Do not trust the
  summary.
- Look for:
  - a test that asserts something other than what its name claims, or that
    would survive breaking the line it guards;
  - a test that cannot see the case it names (a fresh path, a fresh UUID, a fake
    that never reproduces the real behaviour);
  - Swift 6 data races, `@unchecked Sendable` without a lock, a missed
    cancellation path, a second in-flight task per controller;
  - a pasteboard not restored, a secret or transcript text reaching a log, an
    error string or a settings export;
  - an OS-facing call outside a protocol, a concrete service constructed outside
    `AppEnvironment`, an import pointing up the layers;
  - a user-visible failure that is not a `MacomprendoError` with recovery text;
  - a new file missing from `macos/project.yml` / the committed `.xcodeproj`, a
    resource directory declared in only one of the two places;
  - state a human would see and no test covers (a window open while the data
    changes, a control that disappears) — name it for `docs/SMOKE_TEST.md`.
- Return numbered findings `F1…` with `path:line`, the consequence, a concrete
  fix and a severity (blocker / important / minor). No findings: say so in words.
- **Finish** with `kanban_complete`; the summary is the findings in full.

## Task
