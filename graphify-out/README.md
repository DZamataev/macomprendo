# graphify-out

Knowledge graph of this repository, built with [graphify](https://github.com/safishamsi/graphify).
Everything in this directory except this file is **generated, machine-local and
git-ignored** — `graph.json` alone is ~8 MB and `cache/` holds absolute paths from
the machine that built it.

## Rebuild

```bash
uv tool install --upgrade graphifyy    # or: pipx install graphifyy
```

Then, from the repository root, run the `graphify` agent skill on `.` — it detects the
corpus, extracts Swift/Node structure via AST, extracts the docs semantically, clusters,
and writes the outputs below. An incremental refresh after code changes:

```bash
graphify update        # re-extracts only new or changed files
graphify export html   # regenerate the interactive view
```

## What lands here

| File | Contents |
|---|---|
| `graph.json` | the graph itself — nodes, edges, communities |
| `graph.html` | interactive view (aggregates to communities above 5 000 nodes) |
| `GRAPH_REPORT.md` | audit report: god nodes, cohesion, surprising connections |
| `manifest.json` | per-file hashes so `graphify update` knows what changed |
| `cost.json` | cumulative token spend across runs |
| `cache/` | AST and semantic extraction cache |
| `.graphify_*` | interpreter path, scan root, community labels |

## Query it

```bash
graphify query "how does dictation reach the transcription provider"
graphify path "AppEnvironment" "LocalModelManager"
graphify explain "MacomprendoError"
```
