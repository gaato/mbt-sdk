///|
let openrouter_models : Array[String] = [
  "liquid/lfm-2.5-2.6b:free", "nvidia/nemotron-3.5-lightning:free", "qwen/qwen3.8-27b:free",
]

///|
/// One retry only: a stalled :free model should fail over to the next candidate, not burn the budget.
fn live_retry() -> @runtime.RetryPolicy {
  { ..@runtime.RetryPolicy::default(), max_retries: 1, }
}

///|
async fn bounded(f : async () -> Unit) -> Unit {
  @async.with_timeout(240000, f)
}

///|
fn credential(name : String, provider : String) -> String? {
  match @env.get_env_var(name) {
    Some(value) if !value.trim().is_empty() => Some(value)
    _ => {
      println("skip: \{provider}: \{name} is missing or empty")
      None
    }
  }
}

///|
fn optional_setting(name : String) -> String? {
  match @env.get_env_var(name) {
    Some(value) if !value.trim().is_empty() => Some(value)
    _ => None
  }
}

///|
fn runtime_client(api_key : String, base_url : String) -> @runtime.Client {
  @runtime.Client::new(
    @adapter.AsyncTransport::new(timeout_ms=45000),
    @adapter.AsyncClock::new(),
    base_url~,
    auth=@runtime.Bearer(api_key),
    retry=live_retry(),
  )
}

///|
fn openai_error(error : @runtime.SdkError) -> String {
  @debug.to_string(@openai_sdk.api_error(error))
}

///|
fn anthropic_error(error : @runtime.SdkError) -> String {
  @debug.to_string(@anthropic_sdk.api_error(error))
}

///|
fn sdk_failure(
  provider : String,
  model : String,
  explain : (@runtime.SdkError) -> String,
  error : @runtime.SdkError,
) -> String {
  "provider=\{provider} model=\{model} api_error=\{explain(error)} sdk_error=\{@debug.to_string(error)}"
}

///|
async fn[X] with_model_fallback(
  provider : String,
  candidates : Array[String],
  call : async (String) -> X,
  explain : (@runtime.SdkError) -> String,
) -> (String, X) {
  let failures : Array[String] = []
  for model in candidates {
    try call(model) catch {
      @runtime.Transport(inner) =>
        failures.push(
          sdk_failure(provider, model, explain, @runtime.Transport(inner)),
        )
      @runtime.Status(status~, headers~, body~) =>
        failures.push(
          sdk_failure(
            provider,
            model,
            explain,
            @runtime.Status(status~, headers~, body~),
          ),
        )
      @runtime.RateLimited(retry_after_ms~, headers~, body~) =>
        failures.push(
          sdk_failure(
            provider,
            model,
            explain,
            @runtime.RateLimited(retry_after_ms~, headers~, body~),
          ),
        )
      @runtime.Decode(message~, body~) =>
        failures.push(
          sdk_failure(
            provider,
            model,
            explain,
            @runtime.Decode(message~, body~),
          ),
        )
      @runtime.Config(message) =>
        failures.push(
          sdk_failure(provider, model, explain, @runtime.Config(message)),
        )
      error => raise error
    } noraise {
      value => return (model, value)
    }
  }
  fail("all model candidates failed:\n" + failures.join("\n"))
}

///|
async fn[X] one_call(
  provider : String,
  model : String,
  call : async () -> X,
) -> X {
  call() catch {
    @runtime.Transport(inner) =>
      fail(
        sdk_failure(provider, model, openai_error, @runtime.Transport(inner)),
      )
    @runtime.Status(status~, headers~, body~) =>
      fail(
        sdk_failure(
          provider,
          model,
          openai_error,
          @runtime.Status(status~, headers~, body~),
        ),
      )
    @runtime.RateLimited(retry_after_ms~, headers~, body~) =>
      fail(
        sdk_failure(
          provider,
          model,
          openai_error,
          @runtime.RateLimited(retry_after_ms~, headers~, body~),
        ),
      )
    @runtime.Decode(message~, body~) =>
      fail(
        sdk_failure(
          provider,
          model,
          openai_error,
          @runtime.Decode(message~, body~),
        ),
      )
    @runtime.Config(message) =>
      fail(sdk_failure(provider, model, openai_error, @runtime.Config(message)))
    error => raise error
  }
}

///|
async fn[X] one_anthropic_call(
  provider : String,
  model : String,
  call : async () -> X,
) -> X {
  call() catch {
    @runtime.Transport(inner) =>
      fail(
        sdk_failure(provider, model, anthropic_error, @runtime.Transport(inner)),
      )
    @runtime.Status(status~, headers~, body~) =>
      fail(
        sdk_failure(
          provider,
          model,
          anthropic_error,
          @runtime.Status(status~, headers~, body~),
        ),
      )
    @runtime.RateLimited(retry_after_ms~, headers~, body~) =>
      fail(
        sdk_failure(
          provider,
          model,
          anthropic_error,
          @runtime.RateLimited(retry_after_ms~, headers~, body~),
        ),
      )
    @runtime.Decode(message~, body~) =>
      fail(
        sdk_failure(
          provider,
          model,
          anthropic_error,
          @runtime.Decode(message~, body~),
        ),
      )
    @runtime.Config(message) =>
      fail(
        sdk_failure(provider, model, anthropic_error, @runtime.Config(message)),
      )
    error => raise error
  }
}

///|
fn validation_failure(
  provider : String,
  model : String,
  message : String,
) -> Unit raise {
  fail("provider=\{provider} model=\{model} api_error=None: " + message)
}

///|
async test "live OpenRouter OpenAI-compatible Responses API" {
  bounded(() => {
    guard credential("OPENROUTER_API_KEY", "OpenRouter/OpenAI") is Some(key) else {
      return
    }
    let client = @openai_sdk.OpenAI::from_client(
      runtime_client(key, "https://openrouter.ai/api/v1"),
    )
    let models = client.list_models() catch {
      error =>
        fail(
          "provider=OpenRouter/OpenAI model=<list> api_error=\{openai_error(error)} sdk_error=\{@debug.to_string(error)}",
        )
    }
    if models.length() < 100 {
      validation_failure(
        "OpenRouter/OpenAI",
        "<list>",
        "expected at least 100 models, got \{models.length()}",
      )
    }

    let (buffered_model, response) = with_model_fallback(
      "OpenRouter/OpenAI buffered",
      openrouter_models,
      model => {
        client.create_response(
          @openai_sdk.ResponseRequest::new(
            model~,
            input="Reply with one short word.",
            max_output_tokens=1024,
          ),
        )
      },
      openai_error,
    )
    if response.status != @openai_sdk.Completed {
      validation_failure(
        "OpenRouter/OpenAI buffered",
        buffered_model,
        "expected Completed, got \{@debug.to_string(response.status)}",
      )
    }
    if response.output_text.is_empty() {
      validation_failure(
        "OpenRouter/OpenAI buffered", buffered_model, "output_text was empty",
      )
    }

    let (stream_model, stream_result) = with_model_fallback(
      "OpenRouter/OpenAI streaming",
      openrouter_models,
      model => {
        let mut delta_count = 0
        let mut completed = false
        let mut completed_was_last = false
        client.stream_response(
          @openai_sdk.ResponseRequest::new(
            model~,
            input="Reply with one short word.",
            max_output_tokens=1024,
          ),
          event => {
            completed_was_last = false
            match event {
              @openai_sdk.OutputTextDelta(_) => delta_count += 1
              @openai_sdk.Completed(_) => {
                completed = true
                completed_was_last = true
              }
              @openai_sdk.Other(_, _) => ()
              _ => ()
            }
          },
        )
        (delta_count, completed, completed_was_last)
      },
      openai_error,
    )
    if stream_result.0 < 1 {
      validation_failure(
        "OpenRouter/OpenAI streaming", stream_model, "expected at least one OutputTextDelta",
      )
    }
    if !stream_result.1 || !stream_result.2 {
      validation_failure(
        "OpenRouter/OpenAI streaming", stream_model, "stream did not end with Completed",
      )
    }
  })
}

///|
async test "live OpenRouter Anthropic-compatible Messages API" {
  bounded(() => {
    guard credential("OPENROUTER_API_KEY", "OpenRouter/Anthropic") is Some(key) else {
      return
    }
    let client = @anthropic_sdk.Anthropic::new(
      api_key=key,
      @adapter.AsyncTransport::new(timeout_ms=45000),
      @adapter.AsyncClock::new(),
      base_url="https://openrouter.ai/api/v1",
      auth_header=@anthropic_sdk.Bearer,
    )
    let (buffered_model, response) = with_model_fallback(
      "OpenRouter/Anthropic buffered",
      openrouter_models,
      model => {
        client.create_message(
          @anthropic_sdk.MessageRequest::new(model~, max_tokens=1024, messages=[
            @anthropic_sdk.Message::user("Reply with one short word."),
          ]),
        )
      },
      anthropic_error,
    )
    if response.role != @anthropic_sdk.Assistant {
      validation_failure(
        "OpenRouter/Anthropic buffered", buffered_model, "expected role Assistant",
      )
    }
    if response.content.is_empty() {
      validation_failure(
        "OpenRouter/Anthropic buffered", buffered_model, "expected at least one content block",
      )
    }
    if response.usage.output_tokens <= 0 {
      validation_failure(
        "OpenRouter/Anthropic buffered", buffered_model, "expected usage.output_tokens > 0",
      )
    }

    let (stream_model, stream_order) = with_model_fallback(
      "OpenRouter/Anthropic streaming",
      openrouter_models,
      model => {
        let mut start_order = -1
        let mut delta_order = -1
        let mut stop_order = -1
        let mut order = 0
        client.stream_message(
          @anthropic_sdk.MessageRequest::new(model~, max_tokens=1024, messages=[
            @anthropic_sdk.Message::user("Reply with one short word."),
          ]),
          event => {
            match event {
              @anthropic_sdk.MessageStart(_) =>
                if start_order < 0 {
                  start_order = order
                }
              @anthropic_sdk.TextDelta(..)
              | @anthropic_sdk.ThinkingDelta(..)
              | @anthropic_sdk.InputJsonDelta(..) =>
                if delta_order < 0 {
                  delta_order = order
                }
              @anthropic_sdk.MessageStop =>
                if stop_order < 0 {
                  stop_order = order
                }
              _ => ()
            }
            order += 1
          },
        )
        (start_order, delta_order, stop_order)
      },
      anthropic_error,
    )
    if !(stream_order.0 >= 0 &&
      stream_order.1 > stream_order.0 &&
      stream_order.2 > stream_order.1) {
      validation_failure(
        "OpenRouter/Anthropic streaming",
        stream_model,
        "expected MessageStart -> delta -> MessageStop order; got \{stream_order.0}, \{stream_order.1}, \{stream_order.2}",
      )
    }
  })
}

///|
async test "live local OpenAI-compatible Chat Completions API" {
  bounded(() => {
    let base_url = optional_setting("OPENAI_COMPAT_BASE_URL")
    let model = optional_setting("OPENAI_COMPAT_MODEL")
    guard base_url is Some(base_url) && model is Some(model) else {
      println(
        "skip: local OpenAI-compatible: OPENAI_COMPAT_BASE_URL and OPENAI_COMPAT_MODEL are both required",
      )
      return
    }
    let auth = match optional_setting("OPENAI_COMPAT_API_KEY") {
      Some(key) => @runtime.Bearer(key)
      None => @runtime.NoAuth
    }
    let client = @openai_sdk.OpenAI::from_client(
      @runtime.Client::new(
        @adapter.AsyncTransport::new(timeout_ms=45000),
        @adapter.AsyncClock::new(),
        base_url~,
        auth~,
        retry=live_retry(),
      ),
    )
    let models = one_call("local OpenAI-compatible", "<list>", () => {
      client.list_models()
    })
    if models.is_empty() {
      validation_failure(
        "local OpenAI-compatible", "<list>", "model list was empty",
      )
    }
    let completion = one_call("local OpenAI-compatible", model, () => {
      client.chat_completion(
        @openai_sdk.ChatRequest::new(
          model~,
          messages=[@openai_sdk.ChatMessage::user("Reply with one short word.")],
          max_tokens=64,
        ),
      )
    })
    if completion.text.is_empty() {
      validation_failure(
        "local OpenAI-compatible", model, "buffered chat completion text was empty",
      )
    }
    ignore(
      one_call("local OpenAI-compatible tools", model, () => {
        client.chat_completion(
          @openai_sdk.ChatRequest::new(
            model~,
            messages=[
              @openai_sdk.ChatMessage::user("What is the weather in Tokyo?"),
            ],
            max_tokens=64,
            tools=[
              @openai_sdk.ToolDef::new(
                name="get_weather",
                description="Get weather for a city",
                parameters={
                  "type": "object",
                  "properties": { "city": { "type": "string" } },
                  "required": ["city"],
                },
              ),
            ],
          ),
        )
      }),
    )
    let mut delta_count = 0
    let mut finished = false
    let mut finished_was_last_non_usage = false
    one_call("local OpenAI-compatible", model, () => {
      client.stream_chat_completion(
        @openai_sdk.ChatRequest::new(
          model~,
          messages=[@openai_sdk.ChatMessage::user("Reply with one short word.")],
          max_tokens=64,
        ),
        event => {
          match event {
            @openai_sdk.Delta(_) => {
              delta_count += 1
              finished_was_last_non_usage = false
            }
            @openai_sdk.ReasoningDelta(_)
            | @openai_sdk.ToolCallDelta(..)
            | @openai_sdk.Other(_, _) => finished_was_last_non_usage = false
            @openai_sdk.Finished(_) => {
              finished = true
              finished_was_last_non_usage = true
            }
            @openai_sdk.Usage(_) => ()
          }
        },
      )
    })
    if delta_count < 1 || !finished || !finished_was_last_non_usage {
      validation_failure(
        "local OpenAI-compatible", model, "stream lacked Delta or did not end its choice events with Finished",
      )
    }
  })
}

///|
async test "live local Anthropic-compatible Messages API" {
  bounded(() => {
    let base_url = optional_setting("ANTHROPIC_COMPAT_BASE_URL")
    let model = optional_setting("ANTHROPIC_COMPAT_MODEL")
    guard base_url is Some(base_url) && model is Some(model) else {
      println(
        "skip: local Anthropic-compatible: ANTHROPIC_COMPAT_BASE_URL and ANTHROPIC_COMPAT_MODEL are both required",
      )
      return
    }
    let transport = @adapter.AsyncTransport::new(timeout_ms=45000)
    let clock = @adapter.AsyncClock::new()
    let client = match optional_setting("ANTHROPIC_COMPAT_API_KEY") {
      Some(key) =>
        @anthropic_sdk.Anthropic::new(
          api_key=key,
          transport,
          clock,
          base_url~,
          retry=live_retry(),
        )
      None =>
        @anthropic_sdk.Anthropic::from_client(
          @runtime.Client::new(
            transport,
            clock,
            base_url~,
            auth=@runtime.NoAuth,
            retry=live_retry(),
          ),
        )
    }
    let response = one_anthropic_call(
      "local Anthropic-compatible buffered",
      model,
      () => {
        client.create_message(
          @anthropic_sdk.MessageRequest::new(model~, max_tokens=64, messages=[
            @anthropic_sdk.Message::user("Reply with one short word."),
          ]),
        )
      },
    )
    if response.role != @anthropic_sdk.Assistant {
      validation_failure(
        "local Anthropic-compatible buffered", model, "expected role Assistant",
      )
    }
    if response.content.is_empty() {
      validation_failure(
        "local Anthropic-compatible buffered", model, "expected at least one content block",
      )
    }

    let mut start_order = -1
    let mut delta_order = -1
    let mut stop_order = -1
    let mut order = 0
    one_anthropic_call("local Anthropic-compatible streaming", model, () => {
      client.stream_message(
        @anthropic_sdk.MessageRequest::new(model~, max_tokens=64, messages=[
          @anthropic_sdk.Message::user("Reply with one short word."),
        ]),
        event => {
          match event {
            @anthropic_sdk.MessageStart(_) =>
              if start_order < 0 {
                start_order = order
              }
            @anthropic_sdk.TextDelta(..)
            | @anthropic_sdk.ThinkingDelta(..)
            | @anthropic_sdk.InputJsonDelta(..) =>
              if delta_order < 0 {
                delta_order = order
              }
            @anthropic_sdk.MessageStop =>
              if stop_order < 0 {
                stop_order = order
              }
            _ => ()
          }
          order += 1
        },
      )
    })
    if !(start_order >= 0 &&
      delta_order > start_order &&
      stop_order > delta_order) {
      validation_failure(
        "local Anthropic-compatible streaming", model, "expected MessageStart -> delta -> MessageStop order; got {start_order}, {delta_order}, {stop_order}",
      )
    }
  })
}

///|
async test "live OpenAI official minimal operations" {
  bounded(() => {
    guard credential("OPENAI_API_KEY", "OpenAI") is Some(key) else { return }
    let client = @openai_sdk.OpenAI::new(
      api_key=key,
      @adapter.AsyncTransport::new(timeout_ms=45000),
      @adapter.AsyncClock::new(),
    )
    let models = one_call("OpenAI", "<list>", () => client.list_models())
    if models.is_empty() {
      validation_failure("OpenAI", "<list>", "model list was empty")
    }
    let preferred = "gpt-5.4-mini"
    let retrieve_id = if models.any(model => model.id == preferred) {
      preferred
    } else {
      models[0].id
    }
    let retrieved = one_call("OpenAI", retrieve_id, () => {
      client.retrieve_model(retrieve_id)
    })
    if retrieved.id != retrieve_id {
      validation_failure(
        "OpenAI",
        retrieve_id,
        "retrieve_model returned id \{retrieved.id}",
      )
    }
    let embeddings = one_call("OpenAI", "text-embedding-3-small", () => {
      client.create_embeddings(
        @openai_sdk.EmbeddingRequest::new(
          model="text-embedding-3-small",
          input=["hello"],
          dimensions=64,
        ),
      )
    })
    if embeddings.data.length() != 1 ||
      embeddings.data[0].embedding.length() != 64 {
      validation_failure(
        "OpenAI", "text-embedding-3-small", "expected one 64-dimensional embedding",
      )
    }
    let response = one_call("OpenAI", preferred, () => {
      client.create_response(
        @openai_sdk.ResponseRequest::new(
          model=preferred,
          input="Reply with one word.",
          max_output_tokens=16,
        ),
      )
    })
    if response.status != @openai_sdk.Completed ||
      response.output_text.is_empty() {
      validation_failure(
        "OpenAI", preferred, "buffered response was not a nonempty Completed response",
      )
    }
    let mut delta_count = 0
    let mut completed = false
    one_call("OpenAI", preferred, () => {
      client.stream_response(
        @openai_sdk.ResponseRequest::new(
          model=preferred,
          input="Reply with one word.",
          max_output_tokens=16,
        ),
        event => {
          match event {
            @openai_sdk.OutputTextDelta(_) => delta_count += 1
            @openai_sdk.Completed(_) => completed = true
            _ => ()
          }
        },
      )
    })
    if delta_count < 1 || !completed {
      validation_failure(
        "OpenAI", preferred, "stream lacked OutputTextDelta or Completed",
      )
    }
  })
}
