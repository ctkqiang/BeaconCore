{application, beacon_core,
 [{description, "BeaconCore - 从零开始的开源通知引擎"},
  {vsn, "0.1.0"},
  {modules, [
    beacon_core,
    beacon_core_sup,
    ae_public_ws,
    ae_admin_handler,
    ae_routing_engine,
    ae_db
  ]},
  {registered, [beacon_core_sup]},
  {applications, [kernel, stdlib]},
  {mod, {beacon_core, []}},
  {env, []}
 ]}.