# info.lex — the custody agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of this pack's REST pos.PackManifest: how a
# console should PRESENT the custody-ops persona — label, tagline, starter
# prompts. Served by the host under /platform/packs's agent_packs field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "custody", title: "Custody", tagline: "Signed, hash-chained handoffs — the shared custody primitive every other physical-goods pack builds on.", personas: [{ kind: "custody-ops", title: "Custody ops", tagline: "Records handoffs, countersigns them, escalates disputes, and reads a trailer's re-verified journey.", suggested_prompts: ["Record a handoff for trailer TRL-01 from driver-a to driver-b at site depot-north.", "Countersign handoff H-100 as driver-b.", "Dispute handoff H-100 as driver-b: seal was broken on arrival.", "What is trailer TRL-01's custody journey?"] }] }
}

