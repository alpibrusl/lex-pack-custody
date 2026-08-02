# custody.lex — Custody & attestation pack.
#
# Every trailer handoff is a signed, evidence-gated transaction, hash-chained
# PER TRAILER (not per agent run): the releasing party records the handoff
# (seal state, photo hashes, reefer trace ref, site, tractor pair), the
# receiving party countersigns, and the journey endpoint re-derives the whole
# chain's integrity + signature validity on every read. A contested handoff
# escalates through the human gateway like any other approval.
#
# Domain pack over the lex-soft core — assembles lex-trail (hash chain +
# attestations), the deployment Ed25519 identity (human-gateway pattern) and
# hg.request (disputes). Zero core changes.
#
# POST /custody/handoffs                     — record + sign (release side)
# POST /custody/handoffs/:id/countersign     — receiving side signs
# POST /custody/handoffs/:id/dispute         — escalate to the human gateway
# GET  /custody/trailers/:ref/journey        — chained journey, re-verified
#
# Other custody-chain packs (cold-chain, intermodal, agri-food) build on this
# one at the DATA level, not the code level: they query the shared `events`
# table for `kind='custody.handoff'` rows this pack's routes write, keyed by
# the same trailer_ref. Extracting this pack to its own repo does not require
# any change on their side — only whichever deployment mounts both needs this
# package as a dependency.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.map" as map

import "std.http" as http

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-trail/replay" as replay

import "lex-trail/event" as tev

import "lex-trail/attest" as attest

import "lex-soft/src/settlement" as settlement

import "lex-soft/src/human_gateway" as hg

import "lex-soft/src/positions" as pos

import "lex-crypto/src/ed25519" as ed

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jlist_str(j :: jv.Json, key :: Str) -> List[Str] {
  match jv.get_field(j, key) {
    Some(JList(xs)) => list.map(xs, fn (x :: jv.Json) -> Str {
      match x {
        JStr(s) => s,
        _ => "",
      }
    }),
    _ => [],
  }
}

fn not_found(msg :: Str) -> resp.Response {
  { status: 404, body: str.concat("{\"error\":", str.concat(jv.stringify(JStr(msg)), "}")), headers: map.from_list([("content-type", "application/json")]) }
}

# The tip of a trailer's custody chain: the newest handoff event whose
# payload carries this trailer_ref (audit.lex's payload-LIKE precedent).
fn chain_tip(db :: Db, trailer_ref :: Str) -> [sql] Option[Str] {
  let pat := str.concat("%\"trailer_ref\":", str.concat(jv.stringify(JStr(trailer_ref)), "%"))
  match sql.query(db, "SELECT id FROM events WHERE kind='custody.handoff' AND payload_json LIKE ? ORDER BY ts_ms DESC LIMIT 1", [PStr(pat)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => match sql.get_str(row, "id") {
        Some(id) => Some(id),
        None => None,
      },
    },
  }
}

fn event_exists(db :: Db, id :: Str) -> [sql] Bool {
  match sql.query(db, "SELECT id FROM events WHERE id = ? AND kind='custody.handoff'", [PStr(id)]) {
    Err(_) => false,
    Ok(rows) => not list.is_empty(rows),
  }
}

# Sign the handoff EVENT ID: the id is the sha256 of kind|parent|payload|ts,
# so one signature attests the full record AND its position in the chain.
fn sign_event(db :: Db, sign_seed :: Bytes, pub_b64 :: Str, event_id :: Str, by :: Str, role :: Str) -> [sql, time] Result[Str, Str] {
  match ed.sign_text(sign_seed, event_id) {
    Err(e) => Err(e),
    Ok(sig) => {
      let log := settlement.trail_on(db)
      let payload := jv.stringify(JObj([("by", JStr(by)), ("role", JStr(role)), ("sig", JStr(sig)), ("pub", JStr(pub_b64))]))
      match attest.add(log, event_id, "custody.sign", payload) {
        Err(e) => Err(e),
        Ok(_) => Ok(sig),
      }
    },
  }
}

fn attestation_json(db :: Db, event_id :: Str, a :: attest.Attestation) -> jv.Json {
  let __unused := db
  match jv.parse(a.payload_json) {
    Err(_) => JObj([("error", JStr("unreadable attestation"))]),
    Ok(p) => {
      let ok := ed.verify_text(jstr(p, "pub"), event_id, jstr(p, "sig"))
      JObj([("by", JStr(jstr(p, "by"))), ("role", JStr(jstr(p, "role"))), ("sig_valid", JBool(ok))])
    },
  }
}

fn handoff_json(db :: Db, log :: tlog.Log, e :: tev.Event) -> [sql] jv.Json {
  let payload := match jv.parse(e.payload_json) {
    Err(_) => JObj([]),
    Ok(p) => p,
  }
  let sigs := match attest.chain(log, e.id) {
    Err(_) => [],
    Ok(atts) => list.map(list.filter(atts, fn (a :: attest.Attestation) -> Bool {
      a.kind == "custody.sign"
    }), fn (a :: attest.Attestation) -> jv.Json {
      attestation_json(db, e.id, a)
    }),
  }
  JObj([("event_id", JStr(e.id)), ("handoff", payload), ("signatures", JList(sigs))])
}

fn mount(r :: router.Router, db :: Db, sign_seed :: Bytes, pub_b64 :: Str) -> router.Router {
  let with_record := router.route_effectful(r, "POST", "/custody/handoffs", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let trailer_ref := jstr(j, "trailer_ref")
        let to_vin := jstr(j, "to_vin")
        let site := jstr(j, "site")
        let to_agent := jstr(j, "to_agent")
        if str.is_empty(trailer_ref) or str.is_empty(site) or str.is_empty(to_vin) and str.is_empty(to_agent) {
          resp.bad_request("{\"error\":\"trailer_ref, site and a receiving party (to_vin or to_agent) are required\"}")
        } else {
          let by := if str.is_empty(jstr(j, "from_agent")) {
            "dispatcher"
          } else {
            jstr(j, "from_agent")
          }
          let payload := jv.stringify(JObj([("trailer_ref", JStr(trailer_ref)), ("from_vin", JStr(jstr(j, "from_vin"))), ("to_vin", JStr(to_vin)), ("from_agent", JStr(by)), ("to_agent", JStr(jstr(j, "to_agent"))), ("site", JStr(site)), ("seal_state", JStr(jstr(j, "seal_state"))), ("photo_hashes", JList(list.map(jlist_str(j, "photo_hashes"), fn (h :: Str) -> jv.Json {
            JStr(h)
          }))), ("reefer_trace_ref", JStr(jstr(j, "reefer_trace_ref"))), ("mode", JStr(jstr(j, "mode")))]))
          let log := settlement.trail_on(db)
          let parent := chain_tip(db, trailer_ref)
          match tlog.append(log, "custody.handoff", parent, payload) {
            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
            Ok(ev) => match sign_event(db, sign_seed, pub_b64, ev.id, by, "release") {
              Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
              Ok(sig) => resp.json_status(201, jv.stringify(JObj([("event_id", JStr(ev.id)), ("trailer_ref", JStr(trailer_ref)), ("parent", JStr(match parent {
                Some(p) => p,
                None => "",
              })), ("signature", JStr(sig)), ("public_key", JStr(pub_b64))]))),
            },
          }
        }
      },
    }
  })
  let with_counter := router.route_effectful(with_record, "POST", "/custody/handoffs/:id/countersign", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    if not event_exists(db, id) {
      not_found("unknown handoff")
    } else {
      let j := match jv.parse(c.body) {
        Err(_) => JObj([]),
        Ok(v) => v,
      }
      let by := if str.is_empty(jstr(j, "by")) {
        "receiver"
      } else {
        jstr(j, "by")
      }
      let ext_sig := jstr(j, "sig")
      let ext_pub := jstr(j, "pub")
      if not str.is_empty(ext_sig) {
        if ed.verify_text(ext_pub, id, ext_sig) {
          let log := settlement.trail_on(db)
          let payload := jv.stringify(JObj([("by", JStr(by)), ("role", JStr("receive")), ("sig", JStr(ext_sig)), ("pub", JStr(ext_pub))]))
          match attest.add(log, id, "custody.sign", payload) {
            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
            Ok(_) => resp.json(jv.stringify(JObj([("ok", JBool(true)), ("event_id", JStr(id)), ("signature", JStr(ext_sig)), ("public_key", JStr(ext_pub))]))),
          }
        } else {
          resp.bad_request("{\"error\":\"signature does not verify against the supplied public key\"}")
        }
      } else {
        match sign_event(db, sign_seed, pub_b64, id, by, "receive") {
          Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
          Ok(sig) => resp.json(jv.stringify(JObj([("ok", JBool(true)), ("event_id", JStr(id)), ("signature", JStr(sig)), ("public_key", JStr(pub_b64))]))),
        }
      }
    }
  })
  let with_remote := router.route_effectful(with_counter, "POST", "/custody/handoffs/:id/countersign-remote", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    let j := match jv.parse(c.body) {
      Err(_) => JObj([]),
      Ok(v) => v,
    }
    let peer := jstr(j, "peer_url")
    let by := if str.is_empty(jstr(j, "by")) {
      "receiver"
    } else {
      jstr(j, "by")
    }
    if str.is_empty(peer) {
      resp.bad_request("{\"error\":\"peer_url is required (the carrier holding the handoff chain)\"}")
    } else {
      match ed.sign_text(sign_seed, id) {
        Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
        Ok(sig) => {
          let body := jv.stringify(JObj([("by", JStr(by)), ("sig", JStr(sig)), ("pub", JStr(pub_b64))]))
          let url := str.concat(peer, str.concat("/custody/handoffs/", str.concat(id, "/countersign")))
          match http.post(url, bytes.from_str(body), "application/json") {
            Err(_) => resp.json_status(502, "{\"error\":\"peer unreachable\"}"),
            Ok(r) => match bytes.to_str(r.body) {
              Err(_) => resp.json_status(502, "{\"error\":\"peer response unreadable\"}"),
              Ok(b) => resp.json_status(r.status, b),
            },
          }
        },
      }
    }
  })
  let with_dispute := router.route_effectful(with_remote, "POST", "/custody/handoffs/:id/dispute", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    if not event_exists(db, id) {
      not_found("unknown handoff")
    } else {
      let j := match jv.parse(c.body) {
        Err(_) => JObj([]),
        Ok(v) => v,
      }
      let by := if str.is_empty(jstr(j, "by")) {
        "carrier"
      } else {
        jstr(j, "by")
      }
      let reason := jstr(j, "reason")
      match hg.request(db, by, str.concat("Custody dispute on trailer handoff ", id), "custody.dispute", reason) {
        Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
        Ok(approval_id) => {
          let log := settlement.trail_on(db)
          let payload := jv.stringify(JObj([("handoff", JStr(id)), ("by", JStr(by)), ("reason", JStr(reason)), ("approval_id", JStr(approval_id))]))
          let __d := tlog.append(log, "custody.disputed", Some(id), payload)
          resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("approval_id", JStr(approval_id)), ("handoff", JStr(id))])))
        },
      }
    }
  })
  router.route_effectful(with_dispute, "GET", "/custody/trailers/:ref/journey", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    let log := settlement.trail_on(db)
    match chain_tip(db, ref) {
      None => resp.json(jv.stringify(JObj([("trailer_ref", JStr(ref)), ("handoffs", JList([])), ("intact", JBool(true))]))),
      Some(tip) => {
        let chain := list.filter(replay.walk_chain(log, tip), fn (e :: tev.Event) -> Bool {
          e.kind == "custody.handoff"
        })
        let intact := settlement.verify(log, tip)
        let items := list.map(chain, fn (e :: tev.Event) -> [sql] jv.Json {
          handoff_json(db, log, e)
        })
        resp.json(jv.stringify(JObj([("trailer_ref", JStr(ref)), ("handoffs", JList(items)), ("intact", JBool(intact)), ("public_key", JStr(pub_b64))])))
      },
    }
  })
}

# The domain vocabulary this pack speaks (lex-soft/src/positions). Every other
# custody-chain pack (coldchain, intermodal, agrifood, tradefinance) builds on
# this one's handoff/countersign chain, so it is itself a first-class catalogue
# entry, not just infrastructure.
fn manifest() -> pos.PackManifest {
  { id: "custody", title: "Custody", tagline: "Signed, hash-chained handoff — who held the subject, provably.", pattern: "custody_chain", subject: "trailer", subject_ref_field: "trailer_ref", custody_ref_field: "trailer_ref", parties: [{ position: "originator", name: "releaser", title: "Releaser — records and signs the outbound handoff", field: "from_agent", required: true }, { position: "custodian", name: "receiver", title: "Receiver — takes custody and countersigns", field: "to_agent", required: true }, { position: "observer", name: "auditor", title: "Auditor — reads the re-verified journey without acting in the flow", field: "", required: false }], relationships: [{ from: "releaser", to: "receiver", role: "custody", label: "the releaser hands the trailer's custody to the receiver, who must countersign" }, { from: "receiver", to: "auditor", role: "reporting", label: "the re-verified journey is read by whoever audits the chain" }], event_kinds: ["custody.handoff", "custody.disputed"], evidence_kinds: ["signature"], settles: false, route_prefix: "/custody" }
}

