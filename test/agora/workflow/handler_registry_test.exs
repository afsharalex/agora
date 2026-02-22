defmodule Agora.Workflow.HandlerRegistryTest do
  use ExUnit.Case, async: false

  alias Agora.Workflow.HandlerRegistry.Default

  # Tests are async: false because they share the named ETS table.

  setup do
    # Clear all entries before each test
    :ets.delete_all_objects(Default)
    :ok
  end

  describe "register/3" do
    test "registers a handler under a string reference" do
      handler = fn _input -> {:ok, "result"} end
      assert {:ok, :default} = Default.register(:default, "my_handler", handler)
    end

    test "overwrites existing registration" do
      handler1 = fn _input -> {:ok, "first"} end
      handler2 = fn _input -> {:ok, "second"} end

      {:ok, _} = Default.register(:default, "ref", handler1)
      {:ok, _} = Default.register(:default, "ref", handler2)

      {:ok, resolved} = Default.resolve(:default, "ref")
      assert resolved == handler2
    end
  end

  describe "resolve/2" do
    test "resolves a registered handler" do
      handler = fn _input -> {:ok, "result"} end
      {:ok, _} = Default.register(:default, "fetch_ref", handler)

      {:ok, resolved} = Default.resolve(:default, "fetch_ref")
      assert resolved == handler
    end

    test "returns error for unknown reference" do
      assert {:error, error} = Default.resolve(:default, "nonexistent")
      assert error.type == :workflow_error
      assert error.message =~ "Handler not found"
    end
  end

  describe "handler_to_ref/2" do
    test "returns ref for registered handler" do
      handler = fn _input -> {:ok, "result"} end
      {:ok, _} = Default.register(:default, "my_ref", handler)

      {:ok, ref} = Default.handler_to_ref(:default, handler)
      assert ref == "my_ref"
    end

    test "returns error for unregistered handler" do
      handler = fn _input -> {:ok, "not registered"} end

      assert {:error, error} = Default.handler_to_ref(:default, handler)
      assert error.type == :workflow_error
      assert error.message =~ "Handler not registered"
    end
  end

  describe "list/1" do
    test "returns all registered handlers" do
      handler1 = fn _input -> {:ok, "a"} end
      handler2 = fn _input -> {:ok, "b"} end

      {:ok, _} = Default.register(:default, "ref_a", handler1)
      {:ok, _} = Default.register(:default, "ref_b", handler2)

      {:ok, entries} = Default.list(:default)
      assert map_size(entries) == 2
      assert entries["ref_a"] == handler1
      assert entries["ref_b"] == handler2
    end

    test "returns empty map when no handlers registered" do
      {:ok, entries} = Default.list(:default)
      assert entries == %{}
    end
  end

  describe "unregister/2" do
    test "removes a registration" do
      handler = fn _input -> {:ok, "result"} end
      {:ok, _} = Default.register(:default, "ref", handler)
      {:ok, _} = Default.unregister(:default, "ref")

      assert {:error, _} = Default.resolve(:default, "ref")
    end

    test "unregistering nonexistent ref is a no-op" do
      assert {:ok, :default} = Default.unregister(:default, "nonexistent")
    end
  end

  describe "register/resolve round-trip cycle" do
    test "multiple handlers registered and resolved correctly" do
      fetch = fn _input -> {:ok, "fetched"} end
      transform = fn _input -> {:ok, "transformed"} end
      load = fn _input -> {:ok, "loaded"} end

      {:ok, _} = Default.register(:default, "fetch", fetch)
      {:ok, _} = Default.register(:default, "transform", transform)
      {:ok, _} = Default.register(:default, "load", load)

      {:ok, r1} = Default.resolve(:default, "fetch")
      {:ok, r2} = Default.resolve(:default, "transform")
      {:ok, r3} = Default.resolve(:default, "load")

      assert r1 == fetch
      assert r2 == transform
      assert r3 == load

      # Unregister one
      {:ok, _} = Default.unregister(:default, "transform")

      {:ok, entries} = Default.list(:default)
      assert map_size(entries) == 2
      refute Map.has_key?(entries, "transform")
    end
  end
end
