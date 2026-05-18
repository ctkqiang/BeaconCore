-module(main).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, _} = pg:start_link(notification_scope),

    beacon_core_sup:start_link().

stop(_State) ->
    ok.
