defmodule Agora.Tool.HttpTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.Http

  describe "name/0" do
    test "returns http" do
      assert Http.name() == "http"
    end
  end

  describe "timeout/0" do
    test "returns 30_000" do
      assert Http.timeout() == 30_000
    end
  end

  describe "execute/2 - successful request via Req.Test plug" do
    test "makes GET request and returns response" do
      Req.Test.stub(Http.GetTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":"ok"}))
      end)

      context = %{req_options: [plug: {Req.Test, Http.GetTest}]}

      assert {:ok, result} =
               Http.execute(
                 %{"method" => "get", "url" => "http://test.example.com/api"},
                 context
               )

      assert result.status == 200
      assert result.body == %{"result" => "ok"}
    end

    test "makes POST request with body" do
      Req.Test.stub(Http.PostTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "hello"
        Plug.Conn.send_resp(conn, 201, "created")
      end)

      context = %{req_options: [plug: {Req.Test, Http.PostTest}]}

      assert {:ok, result} =
               Http.execute(
                 %{
                   "method" => "post",
                   "url" => "http://test.example.com/api",
                   "body" => "hello"
                 },
                 context
               )

      assert result.status == 201
    end

    test "passes custom headers" do
      Req.Test.stub(Http.HeaderTest, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.send_resp(conn, 200, "auth=#{inspect(auth)}")
      end)

      context = %{req_options: [plug: {Req.Test, Http.HeaderTest}]}

      assert {:ok, _result} =
               Http.execute(
                 %{
                   "method" => "get",
                   "url" => "http://test.example.com/api",
                   "headers" => %{"authorization" => "Bearer token123"}
                 },
                 context
               )
    end
  end

  describe "execute/2 - SSRF protection" do
    test "blocks file:// scheme" do
      assert {:error, msg} =
               Http.execute(%{"method" => "get", "url" => "file:///etc/passwd"}, %{})

      assert msg =~ "Unsupported URL scheme"
    end

    test "blocks ftp:// scheme" do
      assert {:error, msg} =
               Http.execute(%{"method" => "get", "url" => "ftp://evil.com/file"}, %{})

      assert msg =~ "Unsupported URL scheme"
    end

    test "blocks missing scheme" do
      assert {:error, msg} =
               Http.execute(%{"method" => "get", "url" => "just-a-host.com/path"}, %{})

      assert msg =~ "missing"
    end

    test "blocks localhost" do
      assert {:error, msg} =
               Http.execute(%{"method" => "get", "url" => "http://localhost/api"}, %{})

      assert msg =~ "private"
    end

    test "blocks 127.0.0.1" do
      assert {:error, msg} =
               Http.execute(%{"method" => "get", "url" => "http://127.0.0.1/api"}, %{})

      assert msg =~ "private"
    end

    test "blocks 10.0.0.1" do
      assert {:error, msg} =
               Http.execute(%{"method" => "get", "url" => "http://10.0.0.1/api"}, %{})

      assert msg =~ "private"
    end

    test "blocks 172.16.0.1" do
      assert {:error, msg} =
               Http.execute(%{"method" => "get", "url" => "http://172.16.0.1/api"}, %{})

      assert msg =~ "private"
    end

    test "blocks 192.168.1.1" do
      assert {:error, msg} =
               Http.execute(%{"method" => "get", "url" => "http://192.168.1.1/api"}, %{})

      assert msg =~ "private"
    end

    test "blocks 169.254.169.254 (cloud metadata)" do
      assert {:error, msg} =
               Http.execute(
                 %{"method" => "get", "url" => "http://169.254.169.254/latest/meta-data/"},
                 %{}
               )

      assert msg =~ "private"
    end

    test "blocks IPv6 loopback ::1" do
      assert {:error, msg} =
               Http.execute(%{"method" => "get", "url" => "http://[::1]/api"}, %{})

      assert msg =~ "private"
    end
  end
end
