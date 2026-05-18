-module(database_connector).
-behaviour(supervisor).

-export([get_connection/0]).

get_connection() ->
    {ok, "TCP://"}.

