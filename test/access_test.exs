defmodule AgentLink.AccessTest do
  use ExUnit.Case, async: false

  defmodule Deny do
    @behaviour AgentLink.Access

    def authenticate(_conn), do: :reject
    def allowed?(_subject, _runtime), do: false
    def claim(_subject, _name), do: :reject
    def prepare(_mode), do: {:ok, ""}
  end

  defmodule Incomplete do
  end

  defmodule Trio do
    def authenticate(_conn), do: {:ok, %AgentLink.Access.Subject{id: "ada", role: :user}}
    def allowed?(_subject, _name), do: true
    def prepare(_mode), do: {:ok, ""}
  end

  setup do
    token = Application.get_env(:agent_link, :master_token)
    access = Application.get_env(:agent_link, :access)

    on_exit(fn ->
      AgentLink.TestHelpers.restore(:master_token, token)
      AgentLink.TestHelpers.restore(:access, access)
    end)

    :ok
  end

  test "an unset token is not an admin" do
    Application.delete_env(:agent_link, :master_token)
    assert :reject = AgentLink.Access.authenticate(conn("/acp"))
    refute AgentLink.Access.allowed?(%AgentLink.Access.Subject{}, "opencode")

    assert {:error, :not_allowed} =
             AgentLink.Access.claim(%AgentLink.Access.Subject{}, "opencode")
  end

  test "the admin may use any runtime" do
    admin = %AgentLink.Access.Subject{id: "admin", role: :admin}
    assert AgentLink.Access.allowed?(admin, "opencode")
    assert :ok = AgentLink.Access.claim(admin, "opencode")
  end

  test "the master token is accepted and a different token is rejected" do
    Application.put_env(:agent_link, :master_token, "sekret")

    assert {:ok, %AgentLink.Access.Subject{role: :admin}} =
             AgentLink.Access.authenticate(conn("/acp?token=sekret"))

    assert :reject = AgentLink.Access.authenticate(conn("/acp?token=nope"))
    assert :reject = AgentLink.Access.authenticate(conn("/acp"))
  end

  test "the facade calls the configured module" do
    Application.delete_env(:agent_link, :master_token)
    Application.put_env(:agent_link, :access, AgentLink.AccessTest.Deny)
    assert :reject = AgentLink.Access.authenticate(conn("/acp"))

    refute AgentLink.Access.allowed?(
             %AgentLink.Access.Subject{id: "ada", role: :user},
             "opencode"
           )

    assert {:error, :not_allowed} =
             AgentLink.Access.claim(%AgentLink.Access.Subject{id: "ada", role: :user}, "opencode")
  end

  test "the agent socket caller must present the master token" do
    Application.delete_env(:agent_link, :master_token)
    assert {:reject, "No token is set."} = AgentLink.Access.agent_caller(conn("/agent"))

    Application.put_env(:agent_link, :master_token, "sekret")

    assert {:reject, "The master token did not match."} =
             AgentLink.Access.agent_caller(conn("/agent"))

    assert {:ok, %AgentLink.Access.Subject{id: "admin", role: :admin}} =
             AgentLink.Access.agent_caller(conn("/agent?token=sekret"))
  end

  test "an empty subject is not an admin" do
    assert %AgentLink.Access.Subject{id: nil, role: nil} == %AgentLink.Access.Subject{}
  end

  test "a policy without claim still accepts an uplink" do
    Application.put_env(:agent_link, :access, AgentLink.AccessTest.Trio)

    assert :ok =
             AgentLink.Access.claim(%AgentLink.Access.Subject{id: "ada", role: :user}, "opencode")
  end

  test "a missing or incomplete module fails at the call" do
    Application.put_env(:agent_link, :access, AgentLink.Access.Missing)
    assert_raise ArgumentError, ~r/not loaded/, fn -> AgentLink.Access.implementation() end

    Application.put_env(:agent_link, :access, AgentLink.AccessTest.Incomplete)

    assert_raise ArgumentError, ~r/does not implement/, fn ->
      AgentLink.Access.implementation()
    end
  end

  defp conn(path), do: Plug.Test.conn(:get, path)
end
