-module(main).
-behaviour(application).

-export([start/2, stop/1]).

-include("src/header/logger.hrl").

start(_StartType, _StartArgs) ->
    load_env(),

    {ok, _} = pg:start_link(notification_scope),

    beacon_core_supervisor:start_link().

stop(_State) ->
    ok.

load_env() ->
    {ok, Bin} = file:read_file(".env"),
    Lines = binary:split(Bin, <<"\n">>, [global]),
    lists:foreach(fun parse_line/1, Lines).

parse_line(Line) ->
    case binary:split(Line, <<"=">>) of
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
