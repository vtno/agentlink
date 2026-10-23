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

  defmodule Trio do
    def authenticate(_conn), do: {:ok, %Pont.Access.Subject{id: "ada", role: :user}}
    def allowed?(_subject, _name), do: true
    def prepare(_mode), do: {:ok, ""}
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

  test "an unset token is not an admin" do
    Application.delete_env(:pont, :master_token)
    assert :reject = Pont.Access.authenticate(conn("/acp"))
    refute Pont.Access.allowed?(%Pont.Access.Subject{}, "opencode")
    assert {:error, "uplink is not allowed"} = Pont.Access.claim(%Pont.Access.Subject{}, "opencode")
  end

  test "the admin may use any runtime" do
    admin = %Pont.Access.Subject{id: "admin", role: :admin}
    assert Pont.Access.allowed?(admin, "opencode")
    assert :ok = Pont.Access.claim(admin, "opencode")
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

  test "a sidecar must present the master token" do
    Application.delete_env(:pont, :master_token)
    assert {:reject, "PONT_MASTER_TOKEN is not set."} = Pont.Access.sidecar(conn("/agent"))

    Application.put_env(:pont, :master_token, "sekret")
    assert {:reject, "The master token did not match."} = Pont.Access.sidecar(conn("/agent"))
    assert {:ok, %Pont.Access.Subject{id: "admin", role: :admin}} = Pont.Access.sidecar(conn("/agent?token=sekret"))
  end

  test "an empty subject is not an admin" do
    assert %Pont.Access.Subject{id: nil, role: nil} == %Pont.Access.Subject{}
  end

  test "a policy without claim still accepts an uplink" do
    Application.put_env(:pont, :access, Pont.AccessTest.Trio)
    assert :ok = Pont.Access.claim(%Pont.Access.Subject{id: "ada", role: :user}, "opencode")
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
