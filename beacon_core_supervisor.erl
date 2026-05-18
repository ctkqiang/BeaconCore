-module(beacon_core_supervisor).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 3
    },
    
    ChildSpecs = [
        {network_gateway, {network_gateway, start_link, []}, permanent, 5000, worker, [network_gateway]},
        {ae_routing_engine, {ae_routing_engine, start_link, []}, permanent, 5000, worker, [ae_routing_engine]}
    ],
    
    {ok, {SupFlags, ChildSpecs}}.
