///|
test "default random varies and stays in the unit interval" {
  let first = @runtime.default_random()
  assert_true(first >= 0.0 && first < 1.0)
  let mut differs = false
  for _ in 0..<99 {
    let value = @runtime.default_random()
    assert_true(value >= 0.0 && value < 1.0)
    differs = differs || value != first
  }
  assert_true(differs)
}
