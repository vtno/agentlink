defmodule AgentLink.AuthTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:agent_link, :master_token)
    on_exit(fn -> AgentLink.TestHelpers.restore(:master_token, previous) end)
    :ok
  end

  test "an unset token leaves every request open" do
    Application.delete_env(:agent_link, :master_token)
    refute AgentLink.Auth.enabled?()
    assert AgentLink.Auth.headers() == []
    assert AgentLink.Auth.allowed?(conn(:get, "/acp"))
  end

  test "a bearer header and a query token both match" do
    Application.put_env(:agent_link, :master_token, "sekret")
    assert AgentLink.Auth.enabled?()
    assert AgentLink.Auth.headers() == [{"authorization", "Bearer sekret"}]
    assert AgentLink.Auth.allowed?(conn(:get, "/acp", [{"authorization", "Bearer sekret"}]))
    assert AgentLink.Auth.allowed?(conn(:get, "/acp?token=sekret"))
    refute AgentLink.Auth.allowed?(conn(:get, "/acp", [{"authorization", "Bearer nope"}]))
    refute AgentLink.Auth.allowed?(conn(:get, "/acp?token=nope"))
    refute AgentLink.Auth.allowed?(conn(:get, "/acp"))
    refute AgentLink.Auth.allowed?(conn(:get, "/acp", [{"authorization", "Bearer sekre"}]))
  end

  defp conn(method, path, headers \\ []) do
    Plug.Test.conn(method, path, nil)
    |> Map.put(:req_headers, headers)
  end
end
