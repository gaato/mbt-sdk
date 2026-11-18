///|
let credential_names : Array[String] = [
  "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "OPENROUTER_API_KEY", "MBT_SDK_GITHUB_TOKEN",
  "DEEPSEEK_API_KEY", "DASHSCOPE_API_KEY", "ZAI_API_KEY", "MOONSHOT_API_KEY", "GEMINI_API_KEY",
  "VOYAGE_API_KEY", "CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ZONE_ID", "OPENAI_COMPAT_API_KEY",
  "ANTHROPIC_COMPAT_API_KEY",
]

///|
fn credential_values() -> Array[String] {
  credential_names.filter_map(name => {
    @env.get_env_var(name).map(value => value.trim().to_owned())
  })
}

///|
fn preview(text : String, credentials : ArrayView[String]) -> String {
  // Mask before slicing so a credential straddling the limit is still hidden.
  let redacted = credentials.fold(init=text, (text, credential) => {
    text.replace_all(old=credential, new="[redacted]")
  })
  if redacted.length() > 2000 {
    redacted.clamped_view(end=1999).to_owned() + "…"
  } else {
    redacted
  }
}

///|
pub fn format(
  operation : String,
  detail : String,
  status? : Int32,
  body? : Bytes,
  credentials~ : Array[String] = [],
) -> String {
  // An explicit credential supplements the values another provider may echo.
  let credentials = credential_values() + credentials
  // Longer credentials can contain shorter ones.
  let credentials = credentials.filter(value => !value.is_empty())
  credentials.sort_by((a, b) => b.length().compare(a.length()))
  let heading = match status {
    Some(status) => "\{operation}: HTTP \{status} \{detail}"
    None => "\{operation}: \{detail}"
  }
  let heading = preview(heading, credentials)
  match body {
    Some(body) if !body.is_empty() =>
      heading + "\n" + preview(@utf8.decode_lossy(body), credentials)
    _ => heading
  }
}

///|
pub fn response_failure(
  operation : String,
  failure : @client.ResponseFailure,
  credentials~ : Array[String] = [],
) -> String {
  match failure {
    UnexpectedStatus(head, body~) =>
      format(
        operation,
        "unexpected status",
        status=head.status,
        body~,
        credentials~,
      )
    Deserialization(head, message~, body~) =>
      format(
        operation,
        "decode failed: " + message,
        status=head.status,
        body~,
        credentials~,
      )
    @client.ResponseFailure::.. =>
      format(
        operation,
        "response failed",
        status=failure.head().status,
        credentials~,
      )
  }
}
