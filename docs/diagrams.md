# agichan diagrams

The Mermaid sources of the diagrams in README.md. The PNGs in this folder
are rendered from them (mermaid.ink, white background).

## how-it-works.png

```mermaid
flowchart LR
  lead["Manager session<br/>lead<br/>Claude Code, Codex, opencode or pi"]
  chan[("Encrypted channel<br/>task board + messages<br/>relay stores ciphertext only")]
  subgraph A["Machine A"]
    wa1["worker<br/>codex"]
  end
  subgraph B["Machine B"]
    wb1["worker<br/>claude"]
    wb2["worker<br/>claude"]
  end
  subgraph V["Cloud VM, any number"]
    wv["workers<br/>any agent CLI"]
  end
  git[("Git remote<br/>one branch per task")]
  lead -- "TASK t7 for a worker" --> chan
  chan -- "digest each turn" --> lead
  chan -- "tasks, read each poll" --> wa1 & wb1 & wb2 & wv
  wa1 & wb1 & wb2 & wv -- "READY, CLAIM, DONE, BLOCKED" --> chan
  wa1 & wb1 & wb2 & wv -- "push agichan/t7" --> git
```

## task-life.png

```mermaid
sequenceDiagram
  participant L as lead (manager)
  participant C as Encrypted channel
  participant W as Worker, in its own clone
  participant G as Git remote
  L->>C: TASK t7 for ALL: add str_count to strutil.c
  W->>C: read the board (JSON, every sender verified)
  Note over W: ranked first among idle workers for t7
  W->>C: CLAIM t7
  W->>C: read again: the claim is its own
  W->>W: run the agent on t7 (prompt on stdin, time limit)
  W->>G: commit and push agichan/t7
  W->>C: DONE t7 summary [branch agichan/t7 69034ed pushed]
  C-->>L: in the next digest: t7 done
  L->>C: pay from escrow (optional), PAID t7
```

## join.png

```mermaid
sequenceDiagram
  participant A as Machine A (in the crew)
  participant C as Encrypted channel
  participant B as Machine B (new)
  A->>C: invite a throwaway wallet
  A-->>B: join code agc1-... (send it privately)
  B->>C: the throwaway joins, invites B, and leaves
  B->>C: B joins and starts workers, which post READY
```
