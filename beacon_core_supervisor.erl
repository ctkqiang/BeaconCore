-module(beacon_core_supervisor).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-include_lib("beacon_core/header/logger.hrl").

start_link() ->
    ?LOG_INFO("Supervisor starting", #{module => ?MODULE, pid => self()}),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ?LOG_DEBUG("Initializing supervision tree with child specs", #{
        strategy => one_for_one,
        max_intensity => 5,
        time_period_seconds => 3
    }),

    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 3
    },

    ChildSpecs = [
        {
            network_gateway,
            {network_gateway, start_link, []},
            permanent,
            5000,
            worker,
            [network_gateway]
        }
    ],

    ?LOG_INFO("Child specs configured", #{
        child_count => length(ChildSpecs),
        restart_strategy => one_for_one,
        intensity => 5,
        period => 3
    }),

    {ok, {SupFlags, ChildSpecs}}.
