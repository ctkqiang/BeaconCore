-module(network_gateway).
-behaviour(gen_server).

-include_lib("header/logger.hrl").

-export([start_link/0, get_health/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    listen_socket :: gen_tcp:socket() | undefined
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_health() ->
    gen_server:call(?MODULE, check_health).

init([]) ->
    ?LOG_INFO("Network gateway initializing"),

    Port = application:get_env(beacon_core, http_port, 8080),
    ?LOG_DEBUG("Gateway port configured", #{port => Port}),

    SocketOptions = [binary, {reuseaddr, true}, {active, false}],

    case gen_tcp:listen(Port, SocketOptions) of
        {ok, ListenSocket} ->
            ?LOG_NOTICE("Gateway listening on port", #{port => Port}),
            %% Signal the process to immediately jump into its non-blocking accept loop
            self() ! accept_next,
            {ok, #state{listen_socket = ListenSocket}};
        {error, Reason} ->
            ?LOG_ERROR("Gateway failed to bind to port", #{port => Port, reason => Reason}),
            {stop, Reason}
    end.

%% This handles your internal Erlang program-to-program health requests
handle_call(check_health, _From, State) ->
    {reply, {ok, health}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% This handles external HTTP network incoming client connections
handle_info(accept_next, State = #state{listen_socket = ListenSocket}) ->
    case gen_tcp:accept(ListenSocket, 1000) of
        {ok, ClientSocket} ->
            ?LOG_DEBUG("Gateway accepted client connection"),
            spawn(fun() -> handle_client(ClientSocket) end),
            self() ! accept_next,
            {noreply, State};
        {error, timeout} ->
            self() ! accept_next,
            {noreply, State};
        {error, Reason} ->
            ?LOG_ERROR("Gateway accept error", #{reason => Reason}),
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

%% This handles process termination
%% It closes the listening socket and returns ok
terminate(_Reason, #state{listen_socket = ListenSocket}) ->
    if ListenSocket =/= undefined -> gen_tcp:close(ListenSocket); true -> ok end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ====================================================================
%% Internal Network Processing Logic
%% ====================================================================

handle_client(Socket) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} ->
            ?LOG_DEBUG("Raw HTTP request received", #{size_bytes => byte_size(Data)}),
            case parse_http_request(Data) of
                {ok, Method, Path, Headers, Body} ->
                    ?LOG_DEBUG("Parsed HTTP request", #{method => Method, path => Path, headers_count => length(Headers), body_size => byte_size(Body)}),
                    handle_request(Socket, Method, Path, Headers, Body);
                _ ->
                    ?LOG_WARN("Failed to parse HTTP request", #{}),
                    handle_request(Socket, unknown, unknown, [], <<>>)
            end;
        {error, Reason} ->
            ?LOG_ERROR("Socket receive error", #{reason => Reason}),
            gen_tcp:close(Socket)
    end.

parse_http_request(Data) ->
    case binary:split(Data, <<"\r\n">>, [global]) of
        [RequestLine | Rest] ->
            case binary:split(RequestLine, <<" ">>, [global]) of
                [Method, Path, _Protocol | _] ->
                    {Headers, Body} = parse_headers_and_body(Rest),
                    MethodAtom = case string:uppercase(binary_to_list(Method)) of
                        "GET" -> 'GET';
                        "POST" -> 'POST';
                        "PUT" -> 'PUT';
                        "DELETE" -> 'DELETE';
                        _ -> unknown
                    end,
                    {ok, MethodAtom, Path, Headers, Body};
                _ ->
                    error
            end;
        _ ->
            error
    end.

parse_headers_and_body(Lines) ->
    parse_headers_loop(Lines, []).

parse_headers_loop([<<>>|Rest], Headers) ->
    Body = iolist_to_binary(Rest),
    {lists:reverse(Headers), Body};

parse_headers_loop([Line|Rest], Headers) ->
    case binary:split(Line, <<": ">>) of
        [Key, Value] ->
            KeyStr = string:lowercase(binary_to_list(Key)),
            ValStr = binary_to_list(Value),
            parse_headers_loop(Rest, [{KeyStr, ValStr}|Headers]);
        _ ->
            parse_headers_loop(Rest, Headers)
    end;

parse_headers_loop([], Headers) ->
    {lists:reverse(Headers), <<>>}.

handle_request(Socket, 'GET', <<"/health", _/binary>>, _Headers, _Body) ->
    ?LOG_NOTICE("Processing /health request", #{}),

    DbStatus = check_database_status(),
    PgStatus = check_pg_status(),
    AmqpStatus = check_amqp_status(),

    OverallStatus = case {DbStatus, PgStatus} of
        {ok, ok} -> <<"healthy">>;
        _ -> <<"degraded">>
    end,

    ?LOG_DEBUG("Health check results", #{database => DbStatus, process_group => PgStatus, amqp => AmqpStatus, overall => OverallStatus}),

    Body = build_health_response(OverallStatus, DbStatus, PgStatus, AmqpStatus),
    ContentLength = integer_to_binary(byte_size(Body)),

    Response = <<"HTTP/1.1 200 OK\r\n"
                 "Content-Type: application/json; charset=utf-8\r\n"
                 "Content-Length: ", ContentLength/binary, "\r\n"
                 "Cache-Control: no-cache, no-store, must-revalidate\r\n"
                 "Pragma: no-cache\r\n"
                 "Expires: 0\r\n"
                 "X-Content-Type-Options: nosniff\r\n"
                 "X-Frame-Options: DENY\r\n"
                 "X-XSS-Protection: 1; mode=block\r\n"
                 "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\n"
                 "Connection: close\r\n"
                 "\r\n",
                 Body/binary>>,
    gen_tcp:send(Socket, Response),
    ?LOG_NOTICE("Sent /health response", #{status => OverallStatus, size_bytes => byte_size(Body)}),
    gen_tcp:close(Socket);

handle_request(Socket, 'GET', <<"/ws", QueryString/binary>>, Headers, _Body) ->
    ?LOG_NOTICE("WebSocket upgrade request", #{query => QueryString, headers_count => length(Headers)}),
    ae_public_ws:handle_upgrade(Socket, Headers, binary_to_list(QueryString));

handle_request(Socket, 'POST', <<"/v1/admin/broadcast", _/binary>>, _Headers, Body) ->
    ?LOG_NOTICE("Admin broadcast request", #{body_size => byte_size(Body)}),
    ae_admin_handler:handle_request(Socket, 'POST', <<"/v1/admin/broadcast">>, Body);

handle_request(Socket, 'POST', <<"/v1/admin/", _/binary>> = Path, _Headers, Body) ->
    ?LOG_NOTICE("Admin request", #{path => Path, body_size => byte_size(Body)}),
    ae_admin_handler:handle_request(Socket, 'POST', Path, Body);

handle_request(Socket, Method, Path, _Headers, _Body) ->
    ?LOG_WARN("No matching route", #{method => Method, path => Path}),
    NotFound = <<"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found">>,
    gen_tcp:send(Socket, NotFound),
    gen_tcp:close(Socket).

%% Health check helper functions

% Check database connector status
check_database_status() ->
    case pg:get_members(notification_scope, db_workers) of
        [] -> error;
        _ -> ok
    end.

% Check PG (process group) status
check_pg_status() ->
    try
        _ = pg:get_members(notification_scope, db_workers),
        ok
    catch
        _ -> error
    end.

% Check AMQP connectivity status
check_amqp_status() ->
    case application:get_env(beacon_core, amqp_url) of
        {ok, _} -> ok;
        _ -> error
    end.

% Build comprehensive health response JSON
build_health_response(OverallStatus, DbStatus, PgStatus, AmqpStatus) ->
    Timestamp = get_timestamp(),
    Uptime = get_uptime(),
    Memory = get_memory_usage(),

    StatusMap = iolist_to_binary([
        <<"{">>,
        <<"\"timestamp\":\"">>, Timestamp, <<"\",">>,
        <<"\"status\":\"">>, OverallStatus, <<"\",">>,
        <<"\"uptime_seconds\":">>, Uptime, <<",">>,
        <<"\"services\":{">>,
        <<"\"database\":\"">>, atom_to_binary(DbStatus, utf8), <<"\",">>,
        <<"\"process_group\":\"">>, atom_to_binary(PgStatus, utf8), <<"\",">>,
        <<"\"amqp\":\"">>, atom_to_binary(AmqpStatus, utf8), <<"\"">>,
        <<"},">>,
        <<"\"memory_mb\":">>, Memory, <<",">>,
        <<"\"version\":\"1.0.0\",">>,
        <<"\"node\":\"">>, atom_to_binary(node(), utf8), <<"\"">>,
        <<"}">>
    ]),
    iolist_to_binary(StatusMap).

% Get current timestamp in ISO 8601 format
get_timestamp() ->
    {Date, Time} = calendar:universal_time(),
    DateStr = format_date(Date),
    TimeStr = format_time(Time),
    iolist_to_binary([DateStr, <<"T">>, TimeStr, <<"Z">>]).

format_date({Y, M, D}) ->
    io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D]).

format_time({H, Mi, S}) ->
    io_lib:format("~2..0B:~2..0B:~2..0B", [H, Mi, S]).

% Get uptime in seconds
get_uptime() ->
    {TotalMicros, _} = erlang:statistics(wall_clock),
    TotalSeconds = TotalMicros div 1000000,
    integer_to_binary(TotalSeconds).

% Get memory usage in MB
get_memory_usage() ->
    Total = erlang:memory(total),
    MB = Total div (1024 * 1024),
    integer_to_binary(MB).