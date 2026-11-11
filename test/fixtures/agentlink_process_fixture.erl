%% Handshake fixture for AgentLink.Agent.Process.
%% Mix does not compile this file. The test compiles it with compile:file/2.
-module(agentlink_process_fixture).

-export([start/0]).

start() ->
    case os:getenv("AGENTLINK_FIXTURE_IGNORE_TERM") of
        false ->
            ok;
        _ ->
            os:set_signal(sigterm, ignore)
    end,
    loop().

loop() ->
    case io:get_line("") of
        eof ->
            stamp(),
            erlang:halt(0);
        Line ->
            dispatch(line_text(Line)),
            loop()
    end.

line_text(Line) ->
    unicode:characters_to_list(string:trim(Line, trailing, "\n")).

dispatch("ping") ->
    io:put_chars("pong\n");
dispatch("argv") ->
    write_argv();
dispatch("cwd") ->
    write_cwd();
dispatch("exit") ->
    erlang:halt(17);
dispatch(Line) ->
    dispatch_json_or_env(Line).

dispatch_json_or_env(Line) ->
    case string:prefix(Line, "{") of
        nomatch ->
            dispatch_env(Line);
        _ ->
            dispatch_json(Line)
    end.

dispatch_json(Line) ->
    case string:find(Line, "\"op\":\"split\"") of
        nomatch ->
            dispatch_json_newline(Line);
        _ ->
            io:put_chars("{\"method\":\"hi\"}"),
            ready("split")
    end.

dispatch_json_newline(Line) ->
    case string:find(Line, "\"op\":\"newline\"") of
        nomatch ->
            dispatch_json_probe(Line);
        _ ->
            io:put_chars("\n"),
            ready("newline")
    end.

dispatch_json_probe(Line) ->
    case string:find(Line, "\"op\":\"probe\"") of
        nomatch ->
            dispatch_json_stderr(Line);
        _ ->
            probe_reply()
    end.

dispatch_json_stderr(Line) ->
    case string:find(Line, "\"op\":\"stderr\"") of
        nomatch ->
            dispatch_json_exit(Line);
        _ ->
            write_configured_stderr(),
            io:put_chars("{\"method\":\"agentlink.fixture\",\"stderr\":\"ok\"}\n")
    end.

dispatch_json_exit(Line) ->
    case string:find(Line, "\"op\":\"exit\"") of
        nomatch ->
            io:put_chars([Line, "\n"]);
        _ ->
            erlang:halt(17)
    end.

probe_reply() ->
    Args = init:get_plain_arguments(),
    {ok, Cwd} = file:get_cwd(),
    Pid = os:getpid(),
    Body = [
        "{\"method\":\"agentlink.fixture\"",
        ",\"os_pid\":",
        json_string(Pid),
        ",\"cwd\":",
        json_string(Cwd),
        ",\"probe\":",
        json_env("AGENTLINK_PROCESS_PROBE"),
        ",\"args\":",
        json_array(Args),
        "}"
    ],
    io:put_chars([Body, "\n"]).

json_env(Key) ->
    case os:getenv(Key) of
        false ->
            <<"null">>;
        Value ->
            json_string(Value)
    end.

json_array([]) ->
    "[]";
json_array(Args) ->
    ["[", join_args(Args), "]"].

join_args([Arg]) ->
    json_string(Arg);
join_args([Arg | Rest]) ->
    [json_string(Arg), "," | join_args(Rest)].

json_string(Value) ->
    ["\"", escape(to_binary(Value)), "\""].

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) when is_list(Value) ->
    list_to_binary(Value).

escape(Bin) ->
    Bin1 = binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
    Bin2 = binary:replace(Bin1, <<"\"">>, <<"\\\"">>, [global]),
    binary:replace(Bin2, <<"\n">>, <<"\\n">>, [global]).

ready(Text) ->
    case os:getenv("AGENTLINK_FIXTURE_READY") of
        false ->
            ok;
        Path ->
            ok = file:write_file(Path, Text)
    end.

write_configured_stderr() ->
    case {os:getenv("AGENTLINK_STDERR_PATH"), os:getenv("AGENTLINK_STDERR_TOKEN")} of
        {false, _} ->
            ok;
        {_, false} ->
            ok;
        {Path, Token} ->
            ok = file:write_file(Path, Token),
            io:put_chars(standard_error, [Token, "\n"])
    end.

dispatch_env(Line) ->
    case string:prefix(Line, "env ") of
        nomatch ->
            dispatch_echo(Line);
        Key ->
            write_env(Key)
    end.

dispatch_echo(Line) ->
    case string:prefix(Line, "echo ") of
        nomatch ->
            dispatch_stderr(Line);
        Rest ->
            io:put_chars([Rest, "\n"])
    end.

dispatch_stderr(Line) ->
    case string:prefix(Line, "stderr ") of
        nomatch ->
            ok;
        Rest ->
            case string:split(Rest, " ", leading) of
                [Path, Token] ->
                    write_stderr(Path, Token);
                _ ->
                    ok
            end
    end.

write_argv() ->
    Args = init:get_plain_arguments(),
    io:put_chars([integer_to_list(length(Args)), "\n"]),
    lists:foreach(fun write_arg/1, Args).

write_arg(Arg) ->
    Bytes = unicode:characters_to_binary(Arg),
    io:put_chars([integer_to_list(byte_size(Bytes)), "\n", Bytes, "\n"]).

write_cwd() ->
    {ok, Dir} = file:get_cwd(),
    io:put_chars([Dir, "\n"]).

write_env(Key) ->
    case os:getenv(env_name(Key)) of
        false ->
            io:put_chars("unset\n");
        Value ->
            io:put_chars([Value, "\n"])
    end.

env_name(Key) when is_binary(Key) ->
    binary_to_list(Key);
env_name(Key) when is_list(Key) ->
    Key.

write_stderr(Path, Token) ->
    ok = file:write_file(Path, Token),
    io:put_chars(standard_error, [Token, "\n"]),
    io:put_chars("stderr-ok\n").

stamp() ->
    case os:getenv("AGENTLINK_FIXTURE_STAMP") of
        false ->
            ok;
        Path ->
            ok = file:write_file(Path, <<"eof">>)
    end.
