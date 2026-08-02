# lex-pack-custody

Custody & attestation domain pack — signed, hash-chained handoff events (per-asset chain of custody) over lex-soft/lex-trail. The base primitive lex-pack-coldchain, lex-pack-intermodal, lex-pack-agrifood, and lex-pack-tradefinance build on.

> **Status: scaffold.** This pack is being extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) — see [https://github.com/alpibrusl/lex-ev-fleet/issues/235](https://github.com/alpibrusl/lex-ev-fleet/issues/235) for the extraction plan and what still needs to move here. Extract first — the four custody-dependent packs declare this as a lex.toml dependency.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine) -> this pack (one vertical's routes + `pack.DomainPack`) -> [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License

Matches the rest of the lex ecosystem.
