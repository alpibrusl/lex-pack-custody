# tests/test_custody_agent.lex — pure-logic coverage for src/custody_agent.lex.
#
# lex test discards run_all's return value and only checks whether the call
# raises a runtime error -- see lex-ag-ui's README for the full writeup.
# This file forces a real runtime error when count_failures(...) > 0 so
# lex test/lex ci are real gates here.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-llm/src/tool" as t

import "../src/custody_agent" as agent

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn schema_of(name :: Str) -> Option[sch.ModelSchema] {
  match t.find_by_name(agent.make_custody_tools("http://127.0.0.1:8100"), name) {
    None => None,
    Some(tool) => Some(tool.params),
  }
}

fn test_four_tools_defined() -> Result[Unit, Str] {
  assert_true(list.len(agent.make_custody_tools("http://127.0.0.1:8100")) == 4, "custody has exactly 4 REST routes today, so exactly 4 tools should be defined")
}

fn test_record_handoff_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("trailer_ref", JStr("TRL-01")), ("from_vin", JStr("V1")), ("to_agent", JStr("driver-b")), ("site", JStr("depot-north")), ("seal_state", JStr("intact"))])
  match schema_of("record_handoff") {
    None => Err("record_handoff tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("record_handoff's schema must accept custody.lex's documented POST /custody/handoffs body"),
      Ok(_) => pass(),
    },
  }
}

fn test_record_handoff_schema_requires_site() -> Result[Unit, Str] {
  let bad := JObj([("trailer_ref", JStr("TRL-01")), ("to_agent", JStr("driver-b"))])
  match schema_of("record_handoff") {
    None => Err("record_handoff tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("record_handoff's schema must require site"),
    },
  }
}

fn test_countersign_handoff_schema_requires_by() -> Result[Unit, Str] {
  let bad := JObj([("handoff_id", JStr("H-100"))])
  match schema_of("countersign_handoff") {
    None => Err("countersign_handoff tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("countersign_handoff's schema must require by"),
    },
  }
}

fn test_dispute_handoff_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("handoff_id", JStr("H-100")), ("by", JStr("driver-b")), ("reason", JStr("seal broken"))])
  match schema_of("dispute_handoff") {
    None => Err("dispute_handoff tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("dispute_handoff's schema must accept custody.lex's documented POST /custody/handoffs/:id/dispute body"),
      Ok(_) => pass(),
    },
  }
}

fn test_get_trailer_journey_schema_requires_trailer_ref() -> Result[Unit, Str] {
  match schema_of("get_trailer_journey") {
    None => Err("get_trailer_journey tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("get_trailer_journey's schema must require trailer_ref"),
    },
  }
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_four_tools_defined(), test_record_handoff_schema_accepts_documented_shape(), test_record_handoff_schema_requires_site(), test_countersign_handoff_schema_requires_by(), test_dispute_handoff_schema_accepts_documented_shape(), test_get_trailer_journey_schema_requires_trailer_ref()]
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn run_all() -> Int {
  let failures := count_failures(suite_pure())
  let _crash_if_failed := if failures > 0 {
    1 / 0
  } else {
    0
  }
  failures
}

