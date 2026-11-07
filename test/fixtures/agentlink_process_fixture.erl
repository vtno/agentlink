%% Handshake fixture for AgentLink.Agent.Process.
%% Mix does not compile this file. The test compiles it with compile:file/2.
-module(agentlink_process_fixture).

-export([start/0]).

start() ->
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
    dispatch_env(Line).

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
