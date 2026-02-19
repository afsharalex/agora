defmodule AgoraTest do
  use ExUnit.Case

  test "version/0 returns the application version" do
    assert Agora.version() == "0.1.0"
  end
end
