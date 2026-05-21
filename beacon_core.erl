-module(beacon_core).
-behaviour(application).

-export([start/2, stop/1]).

-include_lib("beacon_core/header/logger.hrl").

start(_StartType, _StartArgs) ->
    beacon_logger:set_level(debug),

    io:format(
        "~n~n" ++
        "╔════════════════════════════════════════════════════════════════╗~n" ++
        "║           BeaconCore Application Startup Sequence             ║~n" ++
        "║   Erlang/OTP ~s | PID ~w | Node: ~w~n" ++
        "╚════════════════════════════════════════════════════════════════╝~n~n",
        [erlang:system_info(otp_release), self(), node()]
    ),

    ?LOG_INFO("=== BeaconCore Initialization Started ==="),
    ?LOG_DEBUG("Loading environment configuration", #{
        otp_version => erlang:system_info(otp_release),
        vm_args => erlang:system_info(scheduler_id),
        total_memory_mb => erlang:memory(total) div (1024 * 1024)
    }),

    load_env(),
    ?LOG_INFO("Environment configuration loaded from .env file"),

    ?LOG_DEBUG("Starting process group (PG) for notification scope", #{}),
    {ok, _PgPid} = pg:start_link(notification_scope),
    ?LOG_INFO("Process group initialized", #{pg_pid => _PgPid}),

    ?LOG_DEBUG("Starting supervision tree", #{}),
    case beacon_core_supervisor:start_link() of
        {ok, SupPid} ->
            Port = application:get_env(beacon_core, http_port, 8080),
            AdminKey = application:get_env(beacon_core, admin_api_key, <<"not-set">>),
            RabbitHost = application:get_env(beacon_core, amqp_host, "localhost"),
            RabbitPort = application:get_env(beacon_core, amqp_port, 5672),

            ?LOG_NOTICE("=== BeaconCore Startup Complete ===", #{
                supervisor_pid => SupPid,
                http_port => Port,
                rabbitmq_host => RabbitHost,
                rabbitmq_port => RabbitPort,
                admin_api_configured => (AdminKey =/= <<"not-set">>)
            }),

            io:format(
                "~n╔════════════════════════════════════════════════════════════════╗~n" ++
                "║  [✓] BeaconCore Application is RUNNING and READY                ║~n" ++
                "║                                                                  ║~n" ++
                "║  HTTP Server:    http://127.0.0.1:~w                           ║~n" ++
                "║  Health Check:   http://127.0.0.1:~w/health                   ║~n" ++
                "║  WebSocket:      ws://127.0.0.1:~w/ws                         ║~n" ++
                "║  Admin API:      /v1/admin/broadcast (Bearer token required)    ║~n" ++
                "║  Documentation:  http://127.0.0.1:~w/docs/index.html           ║~n" ++
                "║                                                                  ║~n" ++
                "║  Supervisor PID: ~w                                       ║~n" ++
                "║  Node:           ~w                                      ║~n" ++
                "║  Erlang/OTP:     ~s                                            ║~n" ++
                "╚════════════════════════════════════════════════════════════════╝~n~n",
                [Port, Port, Port, Port, SupPid, node(), erlang:system_info(otp_release)]
            ),

            {ok, SupPid};

        {error, Reason} ->
            ?LOG_FATAL("Failed to start supervision tree", #{reason => Reason, error_type => element(1, Reason)}),
            {error, Reason}
    end.

stop(_State) ->
    ok.

% Load environment variables from .env file
% If .env file is not found, use defaults.
load_env() ->
    %% Guard against missing local environment profiles
    case file:read_file(".env") of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            lists:foreach(fun parse_line/1, Lines);
        {error, Reason} ->
            io:format("Warning: Could not read .env profile (~p). Using defaults.~n", [Reason]),
            ok
    end.

parse_line(Line) ->
    %% Trim carriage returns (\r) out for safe native Windows/MinGW parsing strings
    CleanLine = string:trim(Line, trailing, "\r"),
    case binary:split(CleanLine, <<"=">>) of
        [Key, Value] ->
            KeyStr = binary_to_list(Key),
            ValStr = string:trim(binary_to_list(Value)),
            case mapping(KeyStr) of
                {ok, AppKey, int} ->
                    application:set_env(beacon_core, AppKey, list_to_integer(ValStr));
                {ok, AppKey, str} ->
                    application:set_env(beacon_core, AppKey, ValStr);
                {ok, AppKey, bin} ->
                    application:set_env(beacon_core, AppKey, list_to_binary(ValStr));
                undefined ->
                    ok
            end;
        _ ->
            ok
    end.

mapping("BEAKON_HTTP_PORT")         -> {ok, http_port,         int};
mapping("BEAKON_ADMIN_API_KEY")     -> {ok, admin_api_key,     bin};
mapping("BEAKON_DB_HOST")           -> {ok, db_host,           str};
mapping("BEAKON_DB_PORT")           -> {ok, db_port,           int};
mapping("BEAKON_DB_USER")           -> {ok, db_username,       str};
mapping("BEAKON_DB_PASS")           -> {ok, db_password,       str};
mapping("BEAKON_DB_NAME")           -> {ok, db_database,       str};
mapping("BEAKON_DB_SSL_MODE")       -> {ok, db_ssl,            str};
mapping("BEAKON_AMQP_URL")          -> {ok, amqp_url,          str};
mapping("BEAKON_VAPID_PUBLIC_KEY")  -> {ok, vapid_public_key,  bin};
mapping("BEAKON_VAPID_PRIVATE_KEY") -> {ok, vapid_private_key, bin};
mapping("RABBITMQ_DEFAULT_USER")    -> {ok, amqp_user,         str};
mapping("RABBITMQ_DEFAULT_PASS")    -> {ok, amqp_pass,         str};
mapping("RABBITMQ_HOST")            -> {ok, amqp_host,         str};
mapping("RABBITMQ_PORT")            -> {ok, amqp_port,         int};
mapping("RABBITMQ_MANAGEMENT_PORT") -> {ok, amqp_mgmt_port,    int};
mapping("RABBITMQ_DOCKER_IMAGE")    -> {ok, amqp_docker_image, str};
mapping(_)                          -> undefined.