# zigqueen Performance Principles

`zigqueen` is a clean-room engine, but it is also a performance project.

These principles must shape the implementation from day one.

## Non-negotiables

1. No heap allocation in hot search code.
2. No hidden copies of large search state.
3. Position updates must be incremental and reversible.
4. Core data structures must be cache-friendly and contiguous.
5. Expensive abstractions are not allowed in inner loops.

## Structural choices

### Position
- canonical piece bitboards
- cached occupancies
- mailbox for direct square lookup
- fixed-width scalar fields for side/castling/ep/clocks

### Move storage
- compact move encoding
- fixed-capacity move lists
- no dynamic allocation during generation or ordering

### Search state
- explicit per-search context
- fixed-capacity search stack
- TT owned by engine, not global singleton state
- history/killer/continuation tables in dense arrays

### Evaluation
- modular, but not abstraction-heavy in hot code
- prefer plain functions over indirection
- incremental support added only when correctness is trusted

## Performance discipline

- correctness gate first
- then performance inspection
- then optimization if the structure supports it cleanly

Performance changes must be exact-output and profile-justified; they earn the full
validation ladder only when packaged as a timed-strength candidate.

The rewrite should avoid both extremes:
- slow but elegant toy architecture
- opaque premature micro-optimization without trust
