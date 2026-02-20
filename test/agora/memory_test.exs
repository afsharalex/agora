defmodule Agora.Memory.RaisingBackend do
  @moduledoc false
  @behaviour Agora.Memory

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def get(_state), do: raise("get exploded")

  @impl true
  def save(_state, _messages), do: raise("save exploded")

  @impl true
  def clear(_state), do: raise("clear exploded")
end

defmodule Agora.Memory.RaisingInitBackend do
  @moduledoc false
  @behaviour Agora.Memory

  @impl true
  def init(_opts), do: raise("init exploded")

  @impl true
  def get(_state), do: {:ok, []}

  @impl true
  def save(state, _messages), do: {:ok, state}

  @impl true
  def clear(state), do: {:ok, state}
end

defmodule Agora.Memory.BadErrorBackend do
  @moduledoc false
  @behaviour Agora.Memory

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def get(_state), do: {:error, "plain string error"}

  @impl true
  def save(_state, _messages), do: {:error, :some_atom}

  @impl true
  def clear(_state), do: {:error, 42}
end

defmodule Agora.Memory.BareOkBackend do
  @moduledoc false
  @behaviour Agora.Memory

  @impl true
  def init(_opts), do: :ok

  @impl true
  def get(_state), do: {:ok, []}

  @impl true
  def save(_state, _messages), do: :ok

  @impl true
  def clear(state), do: {:ok, state}
end

defmodule Agora.MemoryTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Memory, Message}

  describe "init/1" do
    test "initializes a valid backend and returns {module, state} tuple" do
      assert {:ok, {Agora.Memory.Buffer, state}} =
               Memory.init({Agora.Memory.Buffer, max_messages: 10})

      assert is_map(state)
    end

    test "returns error for non-loadable module" do
      assert {:error, %Error{type: :memory_error, message: message}} =
               Memory.init({NonExistentModule, []})

      assert message =~ "could not be loaded"
    end

    test "returns error for module missing callbacks" do
      # String is a valid module but doesn't implement Memory callbacks
      assert {:error, %Error{type: :memory_error, message: message}} =
               Memory.init({String, []})

      assert message =~ "does not implement required callbacks"
    end

    test "propagates backend init errors" do
      # Buffer requires :max_messages
      assert {:error, %Error{type: :memory_error}} =
               Memory.init({Agora.Memory.Buffer, []})
    end
  end

  describe "get/1" do
    test "dispatches to backend get" do
      {:ok, memory} = Memory.init({Agora.Memory.Buffer, max_messages: 10})
      assert {:ok, []} = Memory.get(memory)
    end
  end

  describe "save/2" do
    test "dispatches to backend save and returns updated tuple" do
      {:ok, memory} = Memory.init({Agora.Memory.Buffer, max_messages: 10})
      messages = [Message.user("hello")]

      assert {:ok, {Agora.Memory.Buffer, _state}} = Memory.save(memory, messages)
    end

    test "save followed by get round-trips messages" do
      {:ok, memory} = Memory.init({Agora.Memory.Buffer, max_messages: 10})
      messages = [Message.user("hello"), Message.assistant("hi")]

      {:ok, memory} = Memory.save(memory, messages)
      {:ok, retrieved} = Memory.get(memory)

      assert length(retrieved) == 2
      assert Enum.at(retrieved, 0).role == :user
      assert Enum.at(retrieved, 1).role == :assistant
    end
  end

  describe "clear/1" do
    test "dispatches to backend clear and returns updated tuple" do
      {:ok, memory} = Memory.init({Agora.Memory.Buffer, max_messages: 10})
      {:ok, memory} = Memory.save(memory, [Message.user("hello")])

      assert {:ok, {Agora.Memory.Buffer, _state}} = Memory.clear(memory)
    end

    test "get returns empty after clear" do
      {:ok, memory} = Memory.init({Agora.Memory.Buffer, max_messages: 10})
      {:ok, memory} = Memory.save(memory, [Message.user("hello")])
      {:ok, memory} = Memory.clear(memory)

      assert {:ok, []} = Memory.get(memory)
    end
  end

  describe "error safety" do
    test "backend raise in init returns typed error" do
      assert {:error, %Error{type: :memory_error, message: message}} =
               Memory.init({Agora.Memory.RaisingInitBackend, []})

      assert message =~ "init exploded"
    end

    test "backend raise in get returns typed error" do
      {:ok, memory} = Memory.init({Agora.Memory.RaisingBackend, []})

      assert {:error, %Error{type: :memory_error, message: message}} = Memory.get(memory)
      assert message =~ "get exploded"
    end

    test "backend raise in save returns typed error" do
      {:ok, memory} = Memory.init({Agora.Memory.RaisingBackend, []})

      assert {:error, %Error{type: :memory_error, message: message}} =
               Memory.save(memory, [Message.user("hello")])

      assert message =~ "save exploded"
    end

    test "backend raise in clear returns typed error" do
      {:ok, memory} = Memory.init({Agora.Memory.RaisingBackend, []})

      assert {:error, %Error{type: :memory_error, message: message}} = Memory.clear(memory)
      assert message =~ "clear exploded"
    end
  end

  describe "error normalization" do
    test "non-%Error{} error from get is wrapped" do
      {:ok, memory} = Memory.init({Agora.Memory.BadErrorBackend, []})

      assert {:error, %Error{type: :memory_error, message: message}} = Memory.get(memory)
      assert message =~ "returned non-Error"
      assert message =~ "plain string error"
    end

    test "non-%Error{} error from save is wrapped" do
      {:ok, memory} = Memory.init({Agora.Memory.BadErrorBackend, []})

      assert {:error, %Error{type: :memory_error, message: message}} =
               Memory.save(memory, [Message.user("hello")])

      assert message =~ "returned non-Error"
      assert message =~ ":some_atom"
    end

    test "non-%Error{} error from clear is wrapped" do
      {:ok, memory} = Memory.init({Agora.Memory.BadErrorBackend, []})

      assert {:error, %Error{type: :memory_error, message: message}} = Memory.clear(memory)
      assert message =~ "returned non-Error"
    end
  end

  describe "unexpected return normalization" do
    test "bare :ok from init is wrapped as error" do
      assert {:error, %Error{type: :memory_error, message: message}} =
               Memory.init({Agora.Memory.BareOkBackend, []})

      assert message =~ "returned unexpected"
    end

    test "bare :ok from save is wrapped as error" do
      # BareOkBackend.init returns :ok (caught above), so construct tuple directly
      memory = {Agora.Memory.BareOkBackend, %{}}

      assert {:error, %Error{type: :memory_error, message: message}} =
               Memory.save(memory, [Message.user("hello")])

      assert message =~ "returned unexpected"
    end
  end
end
