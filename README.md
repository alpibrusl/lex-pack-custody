# lex-pack-custody

Custody & attestation domain pack — signed, hash-chained handoff events (per-asset chain of custody) over `lex-soft`/`lex-trail`. The base primitive `lex-pack-coldchain`, `lex-pack-intermodal`, `lex-pack-agrifood`, and `lex-pack-tradefinance` build on.

Extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) (see [issue #235](https://github.com/alpibrusl/lex-ev-fleet/issues/235)). The four packs above build on this one at the **data** level (they query the shared `events` table for `kind='custody.handoff'` rows this pack's routes write, keyed by `trailer_ref`), not the code level — none of them import this package directly. Only a deployment mounting both needs this as a `lex.toml` dependency.

## Routes

```
POST /custody/handoffs                     — record + sign (release side)
POST /custody/handoffs/:id/countersign     — receiving side signs
POST /custody/handoffs/:id/countersign-remote — proxy the countersign to a peer
POST /custody/handoffs/:id/dispute         — escalate to the human gateway
GET  /custody/trailers/:ref/journey        — chained journey, re-verified
```

## Usage

```lex
import "lex-pack-custody/custody" as custody

# in your router-wiring code:
let r := custody.mount(router.new(), db, sign_seed, pub_b64)
```

`custody.manifest()` returns the `pos.PackManifest` describing this pack's parties/pattern for the `lex-soft/src/positions` catalogue.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine, primitives) → this pack (`mount()` for the HTTP routes, `manifest()` for the `lex-soft/src/positions` catalogue) → [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License


Copyright (c) 2026 lex-pack-custody contributors.

Licensed under the [EUPL-1.2](LICENSE) — the European Union Public Licence, as used across the `lex-*` ecosystem.

