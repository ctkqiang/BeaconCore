{application, beacon_core, [
    {description, "BeaconCore High-Performance Notification Engine"},
    {vsn, "1.0.0"},
    {modules, [
        beacon_core,
        beacon_core_sup,
        network_gateway,
        database_connector
    ]},
    {registered, [beacon_core_sup, network_gateway]},
    {applications, [kernel, stdlib]},
    {mod, {beacon_core, []}}, %% <-- This tells Erlang which module is the main entry point
    {env, []}
]}.