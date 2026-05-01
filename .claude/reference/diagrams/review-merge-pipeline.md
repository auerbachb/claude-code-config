# Diagram: Review and merge pipeline

<!-- STUB: add decision diamonds for CR / BugBot / Greptile; cite cr-merge-gate.md -->

```mermaid
flowchart LR
  subgraph TODO["TODO — reviewer sticky chain"]
    L["Local CR<br/>coderabbit review"]
    P["Push + PR"]
    G["Merge gate<br/>CI + threads + AC"]
  end
  L --> P --> G
```
