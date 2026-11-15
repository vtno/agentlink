-module(agentlink_stay_fixture).
-export([start/0]).

start() ->
    [Mode | Args] = init:get_plain_arguments(),
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
    receive stop -> ok end.
