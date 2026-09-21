///|
/// Returns the target of the first RFC 8288 Link value whose relation includes
/// `next`, across repeated headers and comma-separated link values.
pub fn parse_link_next(headers : @http.Headers) -> String? {
  for value in headers.get_all("link") {
    for link in split_link_values(value) {
      if parse_next_link(link) is Some(url) {
        return Some(url)
      }
    }
  }
  None
}

///|
fn split_link_values(value : String) -> Array[String] {
  let result = []
  let mut part = StringBuilder()
  let mut in_angle = false
  let mut in_quote = false
  let mut escaped = false
  for c in value {
    if escaped {
      part.write_char(c)
      escaped = false
    } else if in_quote && c == '\\' {
      part.write_char(c)
      escaped = true
    } else if c == '"' && !in_angle {
      part.write_char(c)
      in_quote = !in_quote
    } else if c == '<' && !in_quote {
      part.write_char(c)
      in_angle = true
    } else if c == '>' && !in_quote {
      part.write_char(c)
      in_angle = false
    } else if c == ',' && !in_angle && !in_quote {
      result.push(part.to_string())
      part = StringBuilder()
    } else {
      part.write_char(c)
    }
  }
  result.push(part.to_string())
  result
}

///|
fn parse_next_link(value : String) -> String? {
  let value = value.trim().to_owned()
  guard value.has_prefix("<") else { return None }
  guard value.find(">") is Some(close) else { return None }
  let url = value[1:close].to_owned()
  let params = split_link_params(value[close + 1:].to_owned())
  for param in params {
    guard param.split_once("=") is Some((name, raw)) else { continue }
    if name.trim().to_owned().to_lower() != "rel" {
      continue
    }
    let relation = unquote(raw.trim().to_owned())
    for word in relation.split(" ") {
      let word = word.trim().to_owned()
      if !word.is_empty() && word.to_lower() == "next" {
        return Some(url)
      }
    }
  }
  None
}

///|
fn split_link_params(value : String) -> Array[String] {
  let result = []
  let mut part = StringBuilder()
  let mut in_quote = false
  let mut escaped = false
  for c in value {
    if escaped {
      part.write_char(c)
      escaped = false
    } else if in_quote && c == '\\' {
      part.write_char(c)
      escaped = true
    } else if c == '"' {
      part.write_char(c)
      in_quote = !in_quote
    } else if c == ';' && !in_quote {
      result.push(part.to_string())
      part = StringBuilder()
    } else {
      part.write_char(c)
    }
  }
  result.push(part.to_string())
  result
}

///|
fn unquote(value : String) -> String {
  if value.length() >= 2 && value.has_prefix("\"") && value.has_suffix("\"") {
    let result = StringBuilder()
    let mut escaped = false
    for c in value[1:value.length() - 1] {
      if escaped {
        result.write_char(c)
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else {
        result.write_char(c)
      }
    }
    result.to_string()
  } else {
    value
  }
}
