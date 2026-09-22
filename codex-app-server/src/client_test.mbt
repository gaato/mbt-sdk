///|
fn initialize() -> @protocol.InitializeParams {
  @protocol.InitializeParams::new(
    client_info=@protocol.ClientInfo::new(name="mbt-sdk-test", version="0.1.0"),
  )
}

///|
fn initialize_result() -> Json {
  {
    "userAgent": "test/0.1",
    "codexHome": "/tmp/test",
    "platformFamily": "unix",
    "platformOs": "linux",
  }
}

///|
fn thread_result() -> Json {
  {
    "approvalPolicy": "untrusted",
    "approvalsReviewer": "user",
    "cwd": "/tmp/test",
    "model": "test-model",
    "modelProvider": "test",
    "sandbox": { "type": "readOnly" },
    "thread": {
      "id": "thread-1",
      "cliVersion": "0.155.1",
      "createdAt": 1,
      "updatedAt": 1,
      "cwd": "/tmp/test",
      "ephemeral": true,
      "modelProvider": "test",
      "preview": "",
      "projectId": null,
      "sessionId": "session-1",
      "source": "appServer",
      "status": { "type": "idle" },
      "turns": [],
    },
  }
}

///|
fn[X] pipes(
  group : @async.TaskGroup[X],
) -> (@io.PipeRead, @io.PipeWrite, @io.PipeRead, @io.PipeWrite) {
  let (client_read, server_write) = @io.pipe()
  let (server_read, client_write) = @io.pipe()
  group.add_defer(() => {
    client_read.close()
    client_write.close()
    server_read.close()
    server_write.close()
  })
  (client_read, client_write, server_read, server_write)
}

///|
async test "handshake and typed turn loop with concurrent approval and events" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let (client_read, client_write, server_read, server_write) = pipes(group)
      let initialized : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
      let events : @aqueue.Queue[@protocol.Event] = @aqueue.Queue(
        kind=Unbounded,
      )
      let peer : Ref[@rpc.Connection?] = Ref(None)
      let turn : Json = { "id": "turn-1", "items": [], "status": "inProgress" }
      let server = @rpc.Connection::start(
        group,
        server_read,
        server_write,
        envelope=Bare,
        close_writer=() => server_write.close(),
        on_notification=(name, params) => {
          assert_eq(name, "initialized")
          assert_eq(params, None)
          initialized.put(())
        },
        on_request=(name, params) => {
          match name {
            "initialize" => {
              assert_eq(params, Some(initialize().to_json()))
              Ok(initialize_result())
            }
            "thread/start" => {
              assert_eq(params, Some({ "ephemeral": true }))
              Ok(thread_result())
            }
            "thread/resume" => {
              assert_eq(params, Some({ "threadId": "thread-1" }))
              Ok(thread_result())
            }
            "turn/interrupt" => {
              assert_eq(
                params,
                Some({ "threadId": "thread-1", "turnId": "turn-1" }),
              )
              Ok({})
            }
            "turn/start" => {
              initialized.get()
              let params : @protocol.TurnStartParams = @json.from_json(
                params.unwrap(),
              )
              assert_eq(params.thread_id, "thread-1")
              let peer = peer.val.unwrap()
              peer.notify("turn/started", params={
                "threadId": "thread-1",
                "turn": turn,
              })
              let decision = peer.call(
                "item/commandExecution/requestApproval",
                params={
                  "threadId": "thread-1",
                  "turnId": "turn-1",
                  "itemId": "item-1",
                  "startedAtMs": 1,
                },
              )
              assert_eq(decision, { "decision": "decline" })
              peer.notify("item/agentMessage/delta", params={
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "item-2",
                "delta": "hello",
              })
              peer.notify("turn/completed", params={
                "threadId": "thread-1",
                "turn": { "id": "turn-1", "items": [], "status": "completed" },
              })
              Ok({ "turn": turn })
            }
            _ => Err(@jsonrpc.RpcError::method_not_found(name))
          }
        },
      )
      peer.val = Some(server)
      let client = @codex.connect(
        group,
        client_read,
        client_write,
        initialize(),
        close_writer=() => client_write.close(),
        handlers=@codex.Handlers::new(command=params => {
          assert_eq(params.item_id, "item-1")
          Ok(
            @protocol.CommandExecutionRequestApprovalResponse::new(
              decision=Decline,
            ),
          )
        }),
        on_event=event => events.put(event),
      )
      assert_eq(client.info.user_agent, "test/0.1")
      let thread = client.call(
        @protocol.thread_start(@protocol.ThreadStartParams::new(ephemeral=true)),
      )
      assert_eq(thread.thread.id, "thread-1")
      let resumed = client.call(
        @protocol.thread_resume(
          @protocol.ThreadResumeParams::new(thread_id=thread.thread.id),
        ),
      )
      assert_eq(resumed.thread.id, "thread-1")
      let result = client.call(
        @protocol.turn_start(
          @protocol.TurnStartParams::new(thread_id="thread-1", input=[
            Text(
              @protocol.UserInputText::new(type_="text", text="hello", text_elements=[]),
            ),
          ]),
        ),
      )
      assert_eq(result.turn.id, "turn-1")
      guard events.get() is TurnStarted(started) else {
        fail("missing turn/started")
      }
      assert_eq(started.thread_id, "thread-1")
      guard events.get() is ItemAgentMessageDelta(delta) else {
        fail("missing delta")
      }
      assert_eq(delta.delta, "hello")
      guard events.get() is TurnCompleted(done) else {
        fail("missing completion")
      }
      assert_eq(done.turn.status.to_json(), "completed")
      assert_eq(
        client.call(
          @protocol.turn_interrupt(
            @protocol.TurnInterruptParams::new(
              thread_id="thread-1",
              turn_id="turn-1",
            ),
          ),
        ),
        {},
      )
      client.close()
      assert_true(client.is_closed())
    })
  })
}

///|
async test "handshake timeout closes the connection" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let (client_read, client_write, server_read, server_write) = pipes(group)
      let _server = @rpc.Connection::start(
        group,
        server_read,
        server_write,
        envelope=Bare,
        on_request=(_, _) => {
          @async.sleep(1000)
          Ok(initialize_result())
        },
      )
      let closed = Ref(false)
      try
        @codex.connect(
          group,
          client_read,
          client_write,
          initialize(),
          timeout_ms=10,
          close_writer=() => {
            closed.val = true
            client_write.close()
          },
        )
      catch {
        @rpc.RpcFailure::Timeout(ms) => assert_eq(ms, 10)
        error => raise error
      } noraise {
        _ => fail("expected handshake timeout")
      }
      assert_true(closed.val)
    })
  })
}

///|
async test "cancelling handshake closes output before caller regains control" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let (client_read, client_write, server_read, server_write) = pipes(group)
      let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
      let _server = @rpc.Connection::start(
        group,
        server_read,
        server_write,
        envelope=Bare,
        on_request=(_, _) => {
          started.put(())
          @async.sleep(1000)
          Ok(initialize_result())
        },
      )
      let closed = Ref(false)
      let task = group.spawn(
        () => {
          ignore(
            @codex.connect(group, client_read, client_write, initialize(), close_writer=() => {
              closed.val = true
              client_write.close()
            }),
          )
        },
        allow_failure=true,
      )
      started.get()
      task.cancel()
      try task.wait() catch {
        @async.TaskCancelled => ()
        error => raise error
      } noraise {
        _ => fail("expected cancellation")
      }
      assert_true(closed.val)
    })
  })
}

///|
async test "unknown requests are rejected and invalid approval params never reach handler" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let (client_read, client_write, server_read, server_write) = pipes(group)
      let server = @rpc.Connection::start(
        group,
        server_read,
        server_write,
        envelope=Bare,
        on_request=(_, _) => Ok(initialize_result()),
      )
      let called = Ref(false)
      let client = @codex.connect(
        group,
        client_read,
        client_write,
        initialize(),
        close_writer=() => client_write.close(),
        handlers=@codex.Handlers::new(command=_ => {
          called.val = true
          Ok(
            @protocol.CommandExecutionRequestApprovalResponse::new(
              decision=Decline,
            ),
          )
        }),
      )
      for
        (name, code) in [
          ("item/commandExecution/requestApproval", -32602),
          ("item/fileChange/requestApproval", -32601),
          ("future/request", -32601),
        ] {
        try server.call(name, params={}) catch {
          @rpc.RpcFailure::Remote(error) => assert_eq(error.code, code)
          error => raise error
        } noraise {
          _ => fail("expected remote failure")
        }
      }
      assert_false(called.val)
      try client.call(@protocol.initialize(initialize())) catch {
        @codex.ClientError::AlreadyInitialized => ()
        error => raise error
      } noraise {
        _ => fail("expected duplicate initialization rejection")
      }
    })
  })
}

///|
async test "invalid handshake closes output and malformed results identify method" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let (client_read, client_write, server_read, server_write) = pipes(group)
      let _server = @rpc.Connection::start(
        group,
        server_read,
        server_write,
        envelope=Bare,
        on_request=(_, _) => Ok({}),
      )
      let closed = Ref(false)
      try
        @codex.connect(group, client_read, client_write, initialize(), close_writer=() => {
          closed.val = true
          client_write.close()
        })
      catch {
        @codex.ClientError::InvalidResult(name, _) =>
          assert_eq(name, "initialize")
        error => raise error
      } noraise {
        _ => fail("expected decode failure")
      }
      assert_true(closed.val)
    })
  })
}
