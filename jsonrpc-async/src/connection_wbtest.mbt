///|
test "sends are refused once the writer closes, and only replies outlive close" {
  // (writer_closed, closed, reply, refused)
  let rows : Array[(Bool, Bool, Bool, Bool)] = [
    (false, false, false, false),
    (false, false, true, false),
    (false, true, false, true),
    (false, true, true, false),
    (true, false, false, true),
    (true, false, true, true),
    (true, true, false, true),
    (true, true, true, true),
  ]
  for row in rows {
    let (writer_closed, closed, reply, refused) = row
    assert_eq(
      send_refused(writer_closed~, closed~, reply~),
      refused,
      msg="writer_closed=\{writer_closed} closed=\{closed} reply=\{reply}",
    )
  }
}
