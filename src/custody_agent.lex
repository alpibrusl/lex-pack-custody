# custody_agent.lex — an LLM-driven agent persona that operates THIS pack's
# own REST service (custody.lex's /custody/* routes).
#
# Same loopback-HTTP pattern as lex-pack-construction/src/construction_agent.lex
# -- and already precedented within this exact pack: lex-pack-logistics' TMS
# agent (src/tms.lex, record_handoff tool) already calls this pack's own
# /custody/handoffs route over self_url. This gives custody its own
# first-class persona instead of only being reachable through another
# pack's agent. sign_seed/pub_b64 (mount()'s signing params) never appear
# in any request/response JSON field -- the route signs server-side and
# returns signature/public_key as opaque output, so the agent factory only
# needs self_base_url, not the signing material.

import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

fn http_post_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req1 := http.with_header(req0, "Content-Type", "application/json")
  let req := if str.is_empty(tenant) {
    req1
  } else {
    http.with_header(req1, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  let req := if str.is_empty(tenant) {
    base
  } else {
    http.with_header(base, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Capability ────────────────────────────────────────────────────────────────
fn custody_capability() -> cap.Capability {
  cap.inbound("handle", "Operate signed custody handoffs: record a handoff, countersign one, escalate a dispute, and read a trailer's re-verified custody journey.", { title: "CustodyOps", description: "Inbound message for the custody ops agent.", fields: [sch.required_str("text", [])] })
}

# ── Tools (self — this pack's own REST routes, no external backend) ──────────
fn make_custody_tools(self_base_url :: Str) -> List[t.Tool] {
  [t.define("record_handoff", "Record a signed custody handoff for a trailer: the releasing side's record. Pass to_vin (tractor-to-tractor) or to_agent (to a human/agent party) to say who's receiving custody.", { title: "RecordHandoff", description: "Custody handoff creation.", fields: [sch.required_str("trailer_ref", []), sch.optional(sch.required_str("from_vin", [])), sch.optional(sch.required_str("to_vin", [])), sch.optional(sch.required_str("from_agent", [])), sch.optional(sch.required_str("to_agent", [])), sch.required_str("site", []), sch.optional(sch.required_str("seal_state", [])), sch.optional(sch.required_array("photo_hashes", KStr([]), [])), sch.optional(sch.required_str("reefer_trace_ref", [])), sch.optional(sch.required_str("mode", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/custody/handoffs"), jv.stringify(args), ""))
  }), t.define("countersign_handoff", "Countersign a handoff on the receiving side, confirming custody was accepted.", { title: "CountersignHandoff", description: "Handoff countersignature.", fields: [sch.required_str("handoff_id", []), sch.required_str("by", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/custody/handoffs/", jstr(args, "handoff_id"), "/countersign"], ""), jv.stringify(args), ""))
  }), t.define("dispute_handoff", "Escalate a disputed handoff to the human approval gateway, naming who is disputing it and why.", { title: "DisputeHandoff", description: "Handoff dispute.", fields: [sch.required_str("handoff_id", []), sch.required_str("by", []), sch.required_str("reason", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/custody/handoffs/", jstr(args, "handoff_id"), "/dispute"], ""), jv.stringify(args), ""))
  }), t.define("get_trailer_journey", "Get a trailer's full custody journey: every signed handoff in its hash chain, re-verified for chain integrity and signature validity on read.", { title: "GetTrailerJourney", description: "Trailer journey lookup.", fields: [sch.required_str("trailer_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.join([self_base_url, "/custody/trailers/", jstr(args, "trailer_ref"), "/journey"], ""), ""))
  })]
}

# ── System prompt ──────────────────────────────────────────────────────────────
fn custody_system_prompt(id :: Str) -> Str {
  str.join(["You are custody ops agent ", id, ". You operate signed custody handoffs for trailers.", " Use record_handoff when custody of a trailer changes hands (name to_vin for a tractor-to-tractor swap or to_agent for a human/agent recipient), countersign_handoff once the receiving side confirms, and dispute_handoff to escalate a disagreement to the human gateway. Use get_trailer_journey to check a trailer's full, re-verified chain before answering status questions.", " Be precise about trailer_ref and handoff_id, and always name the specific handoff you acted on."], "")
}

# ── Agent factory (the persona builder the pack mounts) ────────────────────────
fn make_custody_def(db :: Db, id :: Str, base_url :: Str, self_base_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := custody_capability()
  let cfg := { id: id, kind: "custody-ops", system_prompt: custody_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "self_url", url: self_base_url }], intent_roles: [], tools: make_custody_tools(self_base_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("Custody ops agent ", id), "0.1.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

