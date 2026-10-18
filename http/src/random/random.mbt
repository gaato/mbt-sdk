///|
/// Returns a value in [0, 1), using host randomness or a deterministic xorshift64
/// fallback. The fallback is intended for jitter and boundaries, not security.
pub fn default_random() -> Double {
  match @env.rand(6) {
    Some(bytes) => {
      let mut value = 0L
      for byte in bytes {
        value = value * 256L + byte.to_int().to_int64()
      }
      value.to_double() / 281474976710656.0
    }
    None => {
      let mut value = random_state.val
      value = value ^ (value << 13)
      value = value ^ (value >> 7)
      value = value ^ (value << 17)
      random_state.val = value
      (value >> 11).to_double() / 9007199254740992.0
    }
  }
}

///|
/// State of the fallback generator. Its seed is fixed: a caller that needs
/// unpredictable values must not rely on the fallback.
let random_state : Ref[UInt64] = Ref(0x9E3779B97F4A7C15UL)
