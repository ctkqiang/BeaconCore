-module(beacon_core).
-behaviour(application).

-export([start/2, stop/1]).

-include_lib("header/logger.hrl").

start(_StartType, _StartArgs) ->
    beacon_logger:set_level(info),
    load_env(),

    {ok, _PgPid} = pg:start_link(notification_scope),

    case beacon_core_supervisor:start_link() of
        {ok, SupPid} ->
            beacon_logger:log(info, "BeaconCore application initialized successfully.", []),
            Port = application:get_env(beacon_core, http_port, 8080),
            io:format("[BeaconCore] Active | Health check port: ~p~n", [Port]),
            {ok, SupPid};
            
        {error, Reason} ->
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
mapping("BEAKON_DB_HOST")           -> {ok, db_host,           str};
mapping("BEAKON_DB_PORT")           -> {ok, db_port,           int};
mapping("BEAKON_DB_USER")           -> {ok, db_user,           str};
mapping("BEAKON_DB_PASS")           -> {ok, db_pass,           str};
mapping("BEAKON_DB_NAME")           -> {ok, db_name,           str};
mapping("BEAKON_DB_SSL_MODE")       -> {ok, db_ssl,            str};
mapping("BEAKON_AMQP_URL")          -> {ok, amqp_url,          str};
mapping("BEAKON_VAPID_PUBLIC_KEY")  -> {ok, vapid_public_key,  bin};
mapping("BEAKON_VAPID_PRIVATE_KEY") -> {ok, vapid_private_key, bin};
mapping(_)                          -> undefined.