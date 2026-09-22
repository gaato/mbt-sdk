///|
test "optional nullable request fields preserve absent null and value" {
  let absent = @protocol.ThreadStartParams::new()
  assert_eq(absent.to_json(), {})
  let explicit_null = { ..absent, model: @sdkjson.Null, }
  assert_eq(explicit_null.to_json(), { "model": null })
  let value = @protocol.ThreadStartParams::new(
    model="test-model",
    ephemeral=true,
  )
  assert_eq(value.to_json(), { "model": "test-model", "ephemeral": true })
  let decoded : @protocol.ThreadStartParams = @json.from_json(
    explicit_null.to_json(),
  )
  assert_eq(decoded.to_json(), explicit_null.to_json())
}

///|
test "externally tagged approval decisions round trip without stringification" {
  let decline = @protocol.CommandExecutionRequestApprovalResponse::new(
    decision=Decline,
  )
  assert_eq(decline.to_json(), { "decision": "decline" })
  let amended : Json = {
    "decision": {
      "acceptWithExecpolicyAmendment": { "execpolicy_amendment": ["echo"] },
    },
  }
  let result : @protocol.CommandExecutionRequestApprovalResponse = @json.from_json(
    amended,
  )
  assert_eq(result.to_json(), amended)
  for
    invalid in [
      ({ "decision": { "acceptWithExecpolicyAmendment": {} } } : Json),
      {
        "decision": {
          "acceptWithExecpolicyAmendment": {},
          "applyNetworkPolicyAmendment": {},
        },
      },
    ] {
    try
      (
        @json.from_json(invalid) :
        @protocol.CommandExecutionRequestApprovalResponse)
    catch {
      @json.JsonDecodeError(_) => ()
    } noraise {
      _ => fail("invalid known approval payload accepted")
    }
  }
}

///|
test "unknown event and item retain original data but malformed known event fails" {
  let payload : Json = { "future": [1, null, "x"] }
  guard @protocol.Event::decode("future/event", Some(payload))
    is Unknown(name, Some(raw)) else {
    fail("expected unknown event")
  }
  assert_eq(name, "future/event")
  assert_eq(raw, payload)
  let item_json : Json = { "type": "futureItem", "id": "i", "future": [1] }
  let item : @protocol.ThreadItem = @json.from_json(item_json)
  assert_eq(item.to_json(), item_json)
  try
    @protocol.Event::decode("turn/completed", Some({ "threadId": "t" }))
  catch {
    @json.JsonDecodeError(_) => ()
  } noraise {
    _ => fail("invalid known event accepted")
  }
}

///|
test "uint64 protocol numbers retain all bits through JSON" {
  let raw = @json.parse("18446744073709551615")
  let number : @protocol.UInt64Number = @json.from_json(raw)
  assert_eq(number.value, 18446744073709551615UL)
  assert_eq(number.to_json().stringify(), "18446744073709551615")
  let range : @protocol.ByteRange = @json.from_json({ "start": 0, "end": raw })
  assert_eq(range.end.value, number.value)
  assert_eq(
    range.to_json().stringify(),
    "{\"end\":18446744073709551615,\"start\":0}",
  )
  for invalid in ["-1", "1.5", "18446744073709551616", "\"12\""] {
    try (@json.from_json(@json.parse(invalid)) : @protocol.UInt64Number) catch {
      @json.JsonDecodeError(_) => ()
      error => raise error
    } noraise {
      _ => fail("invalid uint64 accepted")
    }
  }
}

///|
test "nested external session source and protocol unknown variants remain distinct" {
  for
    raw in [
      ("unknown" : Json),
      { "custom": "integration" },
      { "subAgent": { "other": "future" } },
    ] {
    let source : @protocol.SessionSource = @json.from_json(raw)
    assert_eq(source.to_json(), raw)
  }
  let known : @protocol.CommandAction = @json.from_json({
    "type": "unknown",
    "command": "echo",
  })
  guard known is KnownUnknown(action) else {
    fail("expected known unknown-command variant")
  }
  assert_eq(action.command, "echo")
}
