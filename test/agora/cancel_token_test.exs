defmodule Agora.CancelTokenTest do
  use ExUnit.Case, async: true

  alias Agora.CancelToken

  describe "new/0" do
    test "returns an uncancelled token" do
      token = CancelToken.new()
      assert %CancelToken{ref: ref} = token
      assert is_reference(ref)
      refute CancelToken.cancelled?(token)
    end
  end

  describe "cancel/1" do
    test "transitions token to cancelled" do
      token = CancelToken.new()
      refute CancelToken.cancelled?(token)

      assert :ok = CancelToken.cancel(token)
      assert CancelToken.cancelled?(token)
    end

    test "is idempotent" do
      token = CancelToken.new()
      assert :ok = CancelToken.cancel(token)
      assert :ok = CancelToken.cancel(token)
      assert CancelToken.cancelled?(token)
    end
  end

  describe "cancelled?/1" do
    test "returns false for new token" do
      refute CancelToken.cancelled?(CancelToken.new())
    end

    test "returns true after cancel" do
      token = CancelToken.new()
      CancelToken.cancel(token)
      assert CancelToken.cancelled?(token)
    end

    test "visible across processes" do
      token = CancelToken.new()
      parent = self()

      spawn(fn ->
        CancelToken.cancel(token)
        send(parent, :cancelled)
      end)

      assert_receive :cancelled
      assert CancelToken.cancelled?(token)
    end
  end
end
