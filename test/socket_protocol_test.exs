defmodule Pont.SocketProtocolTest do
  use ExUnit.Case, async: true

  test "permanent rejections have distinct codes and wire-safe reasons" do
    for {rejection, code, reason} <- [
          {:name_taken, 4001, ~s(name "lab" is in use; stop the other relay or change name)},
          {:instance_too_long, 4002, "instance id is too long; max is 128 bytes"},
          {:bad_name, 4003, "link name must be a short slug"},
          {:not_allowed, 4004, "uplink is not allowed"}
        ] do
      assert Pont.SocketProtocol.close_code(rejection) == code
      assert Pont.SocketProtocol.rejection(code) == rejection
      assert Pont.SocketProtocol.reason(rejection, "lab") == reason
      assert byte_size(Pont.SocketProtocol.reason(rejection, String.duplicate("a", 41))) <= 123
      assert byte_size(Pont.SocketProtocol.reason(rejection)) <= 123
    end

    assert Pont.SocketProtocol.max_instance_bytes() == 128
  end

  test "normal and unknown close codes remain transient" do
    for code <- [1000, 1001, 1011, 4000, 4005, 4999] do
      assert Pont.SocketProtocol.rejection(code) == nil
    end
  end
end
