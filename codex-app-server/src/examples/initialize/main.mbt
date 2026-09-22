///|
/// Handshake-only smoke check. Requires an explicit isolated CODEX_HOME path.
async fn main {
  let args = @env.args()
  guard args.length() == 2 else {
    fail("usage: initialize <isolated-codex-home>")
  }
  @async.with_task_group(group => {
    let session = @codex.spawn(
      group,
      @protocol.InitializeParams::new(
        client_info=@protocol.ClientInfo::new(
          name="mbt-sdk-smoke",
          version="0.1.0",
        ),
      ),
      extra_env={ "CODEX_HOME": args[1] },
    )
    println("initialize: OK (\{session.client.info.platform_os})")
    let code = session.shutdown()
    guard code == 0 else { fail("app-server exited with \{code}") }
    println("shutdown: OK")
  })
}
