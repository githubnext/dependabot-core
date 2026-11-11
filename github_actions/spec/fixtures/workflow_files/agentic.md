---
on: workflow_dispatch
permissions:
  contents: read
engine: copilot
strict: false
pre-agent-steps:
  - uses: actions/setup-node@v4
    with:
      node-version: "22"
---

# Agentic workflow

Leave these instructions unchanged, including this example:

```yaml
steps:
  - uses: actions/setup-node@v4
```
