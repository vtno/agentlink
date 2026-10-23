defmodule Pont.AuthTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:pont, :master_token)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  test "an unset token leaves every request open" do
    Application.delete_env(:pont, :master_token)
    refute Pont.Auth.enabled?()
    assert Pont.Auth.headers() == []
    assert Pont.Auth.allowed?(conn(:get, "/acp"))
  end

  test "a bearer header and a query token both match" do
    Application.put_env(:pont, :master_token, "sekret")
    assert Pont.Auth.enabled?()
    assert Pont.Auth.headers() == [{"authorization", "Bearer sekret"}]
    assert Pont.Auth.allowed?(conn(:get, "/acp", [{"authorization", "Bearer sekret"}]))
    assert Pont.Auth.allowed?(conn(:get, "/acp?token=sekret"))
    refute Pont.Auth.allowed?(conn(:get, "/acp", [{"authorization", "Bearer nope"}]))
    refute Pont.Auth.allowed?(conn(:get, "/acp?token=nope"))
    refute Pont.Auth.allowed?(conn(:get, "/acp"))
    refute Pont.Auth.allowed?(conn(:get, "/acp", [{"authorization", "Bearer sekre"}]))
  end

  defp conn(method, path, headers \\ []) do
    Plug.Test.conn(method, path, nil)
    |> Map.put(:req_headers, headers)
  end

  defp restore(nil), do: Application.delete_env(:pont, :master_token)
  defp restore(value), do: Application.put_env(:pont, :master_token, value)
end
