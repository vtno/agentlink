defmodule Pont.AccessTest do
  use ExUnit.Case, async: false

  defmodule Deny do
    @behaviour Pont.Access

    def authenticate(_conn), do: :reject
    def allowed?(_subject, _runtime), do: false
    def claim(_subject, _name), do: :reject
    def prepare(_mode), do: {:ok, ""}
  end

  defmodule Incomplete do
  end

  setup do
    token = Application.get_env(:pont, :master_token)
    access = Application.get_env(:pont, :access)

    on_exit(fn ->
      restore(:master_token, token)
      restore(:access, access)
    end)

    :ok
  end

  test "an unset token is the admin, and the admin may use any runtime" do
    Application.delete_env(:pont, :master_token)
    assert {:ok, %Pont.Access.Subject{id: "admin", role: :admin}} = Pont.Access.authenticate(conn("/acp"))
    assert Pont.Access.allowed?(%Pont.Access.Subject{}, "opencode")
    assert :ok = Pont.Access.claim(%Pont.Access.Subject{}, "opencode")
  end

  test "the master token is accepted and a different token is rejected" do
    Application.put_env(:pont, :master_token, "sekret")
    assert {:ok, %Pont.Access.Subject{role: :admin}} = Pont.Access.authenticate(conn("/acp?token=sekret"))
    assert :reject = Pont.Access.authenticate(conn("/acp?token=nope"))
    assert :reject = Pont.Access.authenticate(conn("/acp"))
  end

  test "the facade calls the configured module" do
    Application.delete_env(:pont, :master_token)
    Application.put_env(:pont, :access, Pont.AccessTest.Deny)
    assert :reject = Pont.Access.authenticate(conn("/acp"))
    refute Pont.Access.allowed?(%Pont.Access.Subject{id: "ada", role: :user}, "opencode")
    assert {:error, "uplink is not allowed"} = Pont.Access.claim(%Pont.Access.Subject{id: "ada", role: :user}, "opencode")
  end

  test "a missing or incomplete module fails at the call" do
    Application.put_env(:pont, :access, Pont.Access.Missing)
    assert_raise ArgumentError, ~r/not loaded/, fn -> Pont.Access.implementation() end

    Application.put_env(:pont, :access, Pont.AccessTest.Incomplete)
    assert_raise ArgumentError, ~r/does not implement/, fn -> Pont.Access.implementation() end
  end

  defp conn(path), do: Plug.Test.conn(:get, path)

  defp restore(key, nil), do: Application.delete_env(:pont, key)
  defp restore(key, value), do: Application.put_env(:pont, key, value)
end
