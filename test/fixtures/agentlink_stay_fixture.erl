-module(agentlink_stay_fixture).
-export([start/0]).

start() ->
    [Mode | Args] = init:get_plain_arguments(),
    run(Mode, Args).

run("read", [Path]) ->
    Parent = self(),
    spawn(fun() ->
        {ok, File} = file:open(Path, [read, raw]),
        Parent ! {line, read_line(File, [])}
    end),
    receive
        {line, Line} when is_list(Line), Line =/= [] ->
            io:put_chars(Line),
            erlang:halt(0);
        _ -> erlang:halt(1)
    after 30000 ->
        erlang:halt(1)
    end;
run(Mode, Args) ->
    case Mode of
        "unrelated" -> ok;
        "child" -> os:set_signal(sighup, ignore);
        _ ->
            os:set_signal(sigterm, ignore),
            os:set_signal(sighup, ignore)
    end,
    case Mode of
        "sticky" -> os:set_signal(sigint, ignore);
        _ -> ok
    end,
    case Args of
        [Path] when Path =/= "-" -> ok = file:write_file(Path, os:getpid());
        _ -> ok
    end,
    case Mode of
        "ready" -> io:format("~s~n", [os:getpid()]);
        _ -> ok
    end,
    receive stop -> ok end.

read_line(File, Acc) ->
    case file:read(File, 1) of
        {ok, "\n"} -> lists:reverse(Acc, "\n");
        {ok, [Char]} -> read_line(File, [Char | Acc]);
        _ -> eof
    end.
