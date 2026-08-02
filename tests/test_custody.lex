# tests/test_custody.lex — pure-logic coverage for src/custody.lex.
#
# Covers jstr/jlist_str/not_found and manifest() shape/validity in isolation.
# The effectful routes (sign/verify/DB/trail) need a live DB + Ed25519 seed to
# exercise meaningfully — that's covered by lex-ev-fleet's own integration
# testing of the mounted deployment, the same split test_pv.lex and
# test_solar_input.lex use elsewhere in this ecosystem for effectful-vs-pure.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-soft/src/positions" as pos

import "../src/custody" as custody

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

# ---- jstr -----------------------------------------------------------------
fn test_jstr_returns_string_field() -> Result[Unit, Str] {
  let j := JObj([("trailer_ref", JStr("TR-1"))])
  assert_true(custody.jstr(j, "trailer_ref") == "TR-1", "jstr must read a present string field")
}

fn test_jstr_missing_field_is_empty() -> Result[Unit, Str] {
  let j := JObj([])
  assert_true(custody.jstr(j, "trailer_ref") == "", "jstr must default to empty string for a missing field")
}

fn test_jstr_wrong_type_is_empty() -> Result[Unit, Str] {
  let j := JObj([("trailer_ref", JInt(5))])
  assert_true(custody.jstr(j, "trailer_ref") == "", "jstr must default to empty string when the field is not a JStr")
}

# ---- jlist_str --------------------------------------------------------------
fn test_jlist_str_reads_string_list() -> Result[Unit, Str] {
  let j := JObj([("photo_hashes", JList([JStr("a"), JStr("b")]))])
  let got := custody.jlist_str(j, "photo_hashes")
  assert_true(list.len(got) == 2 and list.head(got) == Some("a"), "jlist_str must read a present JList of JStr")
}

fn test_jlist_str_missing_field_is_empty_list() -> Result[Unit, Str] {
  let j := JObj([])
  assert_true(list.is_empty(custody.jlist_str(j, "photo_hashes")), "jlist_str must default to an empty list for a missing field")
}

fn test_jlist_str_non_string_items_become_empty_strings() -> Result[Unit, Str] {
  let j := JObj([("photo_hashes", JList([JInt(1)]))])
  let got := custody.jlist_str(j, "photo_hashes")
  assert_true(got == [""], "a non-string item in the list must map to an empty string, not be dropped")
}

# ---- not_found --------------------------------------------------------------
fn test_not_found_shape() -> Result[Unit, Str] {
  let r := custody.not_found("unknown handoff")
  assert_true(r.status == 404 and r.body == "{\"error\":\"unknown handoff\"}", "not_found must return a 404 with the message JSON-encoded")
}

# ---- manifest() -------------------------------------------------------------
fn test_manifest_is_valid() -> Result[Unit, Str] {
  let m := custody.manifest()
  assert_true(list.is_empty(pos.validate(m)), "custody's own manifest must satisfy the shared position/pattern validator")
}

fn test_manifest_route_prefix() -> Result[Unit, Str] {
  assert_true(custody.manifest().route_prefix == "/custody", "manifest route_prefix must match the mounted routes")
}

fn test_manifest_names_the_custody_ref_field() -> Result[Unit, Str] {
  let m := custody.manifest()
  assert_true(not list.is_empty(pos.parties_at(m, "custodian")) and m.custody_ref_field == "trailer_ref", "a pack naming a custodian must name its custody_ref_field")
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_jstr_returns_string_field(), test_jstr_missing_field_is_empty(), test_jstr_wrong_type_is_empty(), test_jlist_str_reads_string_list(), test_jlist_str_missing_field_is_empty_list(), test_jlist_str_non_string_items_become_empty_strings(), test_not_found_shape(), test_manifest_is_valid(), test_manifest_route_prefix(), test_manifest_names_the_custody_ref_field()]
}

