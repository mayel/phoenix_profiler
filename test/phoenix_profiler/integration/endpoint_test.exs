Code.require_file("../../support/endpoint_helper.exs", __DIR__)
Code.require_file("../../support/http_client.exs", __DIR__)

defmodule PhoenixProfiler.Integration.EndpointTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  import PhoenixProfiler.Integration.EndpointHelper

  alias __MODULE__.DebugEndpoint
  alias __MODULE__.DisabledEndpoint
  alias __MODULE__.EnabledEndpoint
  alias __MODULE__.NotConfiguredEndpoint
  alias __MODULE__.Profiler

  [debug, disabled, enabled, noconf] = get_unused_port_numbers(4)
  @debug debug
  @disabled disabled
  @enabled enabled
  @noconf noconf

  Application.put_env(:phoenix_profiler, DebugEndpoint,
    http: [port: @debug],
    live_view: [signing_salt: gen_salt()],
    secret_key_base: gen_secret_key(),
    server: true,
    drainer: false,
    debug_errors: true,
    phoenix_profiler: [server: Profiler]
  )

  Application.put_env(:phoenix_profiler, DisabledEndpoint,
    http: [port: @disabled],
    live_view: [signing_salt: gen_salt()],
    secret_key_base: gen_secret_key(),
    server: true,
    drainer: false,
    phoenix_profiler: [server: Profiler, enable: false]
  )

  Application.put_env(:phoenix_profiler, EnabledEndpoint,
    http: [port: @enabled],
    live_view: [signing_salt: gen_salt()],
    secret_key_base: gen_secret_key(),
    server: true,
    drainer: false,
    phoenix_profiler: [server: Profiler]
  )

  Application.put_env(:phoenix_profiler, NotConfiguredEndpoint,
    http: [port: @noconf],
    secret_key_base: gen_secret_key(),
    live_view: [signing_salt: gen_salt()],
    server: true,
    drainer: false
  )

  defmodule Router do
    @moduledoc """
    Let's use a plug router to test this endpoint.
    """
    use Plug.Router

    plug :content_type
    plug :match
    plug :dispatch

    get "/" do
      send_resp(conn, 200, "<html><body>ok</body></html>")
    end

    get "/router/oops" do
      _ = conn
      raise "oops"
    end

    get "/router/catch" do
      _ = conn
      throw(:oops)
    end

    match _ do
      raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__
    end

    def __routes__ do
      []
    end

    def content_type(conn, _) do
      put_resp_header(conn, "content-type", "text/html")
    end
  end

  for mod <- [DebugEndpoint, DisabledEndpoint, EnabledEndpoint, NotConfiguredEndpoint] do
    defmodule mod do
      use Phoenix.Endpoint, otp_app: :phoenix_profiler
      use PhoenixProfiler

      plug :oops
      plug Router

      @doc """
      Verify errors from the plug stack too (before the router).
      """
      def oops(conn, _opts) do
        if conn.path_info == ~w(oops) do
          raise "oops"
        else
          conn
        end
      end
    end
  end

  alias PhoenixProfiler.Integration.HTTPClient

  setup do
    pid = start_supervised!({PhoenixProfiler, name: Profiler})
    {:ok, profiler_pid: pid}
  end

  test "starts collector and injects headers and toolbar and saves profile to storage for debug" do
    # with debug_errors: true
    {:ok, _} = DebugEndpoint.start_link([])

    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@debug}", %{})
    assert resp.status == 200
    assert [token] = HTTPClient.get_resp_header(resp, "x-debug-token")
    assert [link] = HTTPClient.get_resp_header(resp, "x-debug-token-link")
    assert link =~ "/dashboard/_profiler"
    assert resp.body =~ ~s|<div id="pwdt#{token}" class="phxprof-toolbar"|
    assert %PhoenixProfiler.Profile{} = PhoenixProfiler.ProfileStore.get(Profiler, token)

    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@debug}/unknown", %{})
    assert resp.status == 404
    assert [token] = HTTPClient.get_resp_header(resp, "x-debug-token")
    assert [link] = HTTPClient.get_resp_header(resp, "x-debug-token-link")
    assert link =~ "/dashboard/_profiler"
    # assert resp.body =~ ~s|<div id="pwdt#{token}" class="phxprof-toolbar"|
    assert %PhoenixProfiler.Profile{} = PhoenixProfiler.ProfileStore.get(Profiler, token)

    capture_log(fn ->
      # {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@debug}/oops", %{})
      # assert resp.status == 500
      # assert [token] = HTTPClient.get_resp_header(resp, "x-debug-token")
      # assert [link] = HTTPClient.get_resp_header(resp, "x-debug-token-link")
      # assert link =~ "/dashboard/_profiler"
      # assert %PhoenixProfiler.Profile{} = PhoenixProfiler.ProfileStore.get(Profiler, token)

      {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@debug}/router/oops", %{})
      assert resp.status == 500
      assert [token] = HTTPClient.get_resp_header(resp, "x-debug-token")
      assert [link] = HTTPClient.get_resp_header(resp, "x-debug-token-link")
      assert link =~ "/dashboard/_profiler"
      assert %PhoenixProfiler.Profile{} = PhoenixProfiler.ProfileStore.get(Profiler, token)

      Supervisor.stop(DebugEndpoint)
    end) =~ "** (RuntimeError) oops"
  end

  test "starts collector and injects headers and toolbar and saves profile to storage for enabled" do
    # with debug_errors: false
    {:ok, _} = EnabledEndpoint.start_link([])

    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@enabled}", %{})
    assert resp.status == 200
    assert [token] = HTTPClient.get_resp_header(resp, "x-debug-token")
    assert [link] = HTTPClient.get_resp_header(resp, "x-debug-token-link")
    assert link =~ "/dashboard/_profiler"
    assert resp.body =~ ~s|<div id="pwdt#{token}" class="phxprof-toolbar"|
    assert %PhoenixProfiler.Profile{} = PhoenixProfiler.ProfileStore.get(Profiler, token)

    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@enabled}/unknown", %{})
    assert resp.status == 404
    assert resp.body =~ "404.html from PhoenixProfiler.ErrorView"
    assert [token] = HTTPClient.get_resp_header(resp, "x-debug-token")
    assert [link] = HTTPClient.get_resp_header(resp, "x-debug-token-link")
    assert link =~ "/dashboard/_profiler"
    # assert resp.body =~ ~s|<div id="pwdt#{token}" class="phxprof-toolbar"|
    assert %PhoenixProfiler.Profile{} = PhoenixProfiler.ProfileStore.get(Profiler, token)

    # skips phoenix_live_reload frame
    for path <- ["phoenix/live_reload/frame", "phoenix/live_reload/frame/suffix"] do
      {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@enabled}/#{path}", %{})
      assert HTTPClient.get_resp_header(resp, "x-debug-token") == []
      assert HTTPClient.get_resp_header(resp, "x-debug-token-link") == []
    end

    capture_log(fn ->
      # {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@enabled}/oops", %{})
      # assert resp.status == 500
      # assert [token] = HTTPClient.get_resp_header(resp, "x-debug-token")
      # assert [link] = HTTPClient.get_resp_header(resp, "x-debug-token-link")
      # assert link =~ "/dashboard/_profiler"
      # assert %PhoenixProfiler.Profile{} = PhoenixProfiler.ProfileStore.get(Profiler, token)

      {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@enabled}/router/oops", %{})
      assert resp.status == 500
      assert [token] = HTTPClient.get_resp_header(resp, "x-debug-token")
      assert [link] = HTTPClient.get_resp_header(resp, "x-debug-token-link")
      assert link =~ "/dashboard/_profiler"
      assert %PhoenixProfiler.Profile{} = PhoenixProfiler.ProfileStore.get(Profiler, token)

      Supervisor.stop(EnabledEndpoint)
    end) =~ "** (RuntimeError) oops"
  end

  test "skips injecting headers and toolbar and profile storage for disabled" do
    {:ok, _} = DisabledEndpoint.start_link([])

    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@disabled}", %{})
    assert resp.status == 200
    assert HTTPClient.get_resp_header(resp, "x-debug-token") == []
    assert HTTPClient.get_resp_header(resp, "x-debug-token-link") == []
    refute resp.body =~ ~s|class="phxprof-toolbar"|

    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@disabled}/unknown", %{})
    assert resp.status == 404
    assert HTTPClient.get_resp_header(resp, "x-debug-token") == []
    assert HTTPClient.get_resp_header(resp, "x-debug-token-link") == []
    refute resp.body =~ ~s|class="phxprof-toolbar"|

    capture_log(fn ->
      # {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@enabled}/oops", %{})
      # assert resp.status == 500
      # assert [token] = HTTPClient.get_resp_header(resp, "x-debug-token")
      # assert [link] = HTTPClient.get_resp_header(resp, "x-debug-token-link")
      # assert link =~ "/dashboard/_profiler"
      # assert %PhoenixProfiler.Profile{} = PhoenixProfiler.ProfileStore.get(Profiler, token)

      {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@disabled}/router/oops", %{})
      assert resp.status == 500
      assert HTTPClient.get_resp_header(resp, "x-debug-token") == []
      assert HTTPClient.get_resp_header(resp, "x-debug-token-link") == []

      Supervisor.stop(DisabledEndpoint)
    end) =~ "** (RuntimeError) oops"
  end

  test "skips headers and toolbar and profile storage for not configured" do
    {:ok, _} = NotConfiguredEndpoint.start_link([])

    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@noconf}", %{})
    assert resp.status == 200
    assert HTTPClient.get_resp_header(resp, "x-debug-token") == []
    assert HTTPClient.get_resp_header(resp, "x-debug-token-link") == []
    refute resp.body =~ ~s|class="phxprof-toolbar"|

    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@noconf}/unknown", %{})
    assert resp.status == 404
    assert HTTPClient.get_resp_header(resp, "x-debug-token") == []
    assert HTTPClient.get_resp_header(resp, "x-debug-token-link") == []
    refute resp.body =~ ~s|class="phxprof-toolbar"|

    capture_log(fn ->
      {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@noconf}/router/oops", %{})
      assert resp.status == 500
      assert HTTPClient.get_resp_header(resp, "x-debug-token") == []
      assert HTTPClient.get_resp_header(resp, "x-debug-token-link") == []

      Supervisor.stop(NotConfiguredEndpoint)
    end) =~ "** (RuntimeError) oops"
  end

  test "skips injecting header and toolbar for phoenix_live_reload iframes" do
    start_supervised!(EnabledEndpoint)
    start_supervised!(DisabledEndpoint)

    for port <- [@disabled, @enabled],
        path <- ["phoenix/live_reload/frame", "phoenix/live_reload/frame/suffix"] do
      {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{port}/#{path}", %{})
      assert HTTPClient.get_resp_header(resp, "x-debug-token") == []
      assert HTTPClient.get_resp_header(resp, "x-debug-token-link") == []
    end
  end
end
