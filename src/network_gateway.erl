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

    SocketOptions = [binary, {packet, http}, {reuseaddr, true}, {active, false}],

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
            spawn_link(fun() -> handle_client(ClientSocket) end),
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
        {ok, {http_request, Method, Path, Version}} ->
            io:format("[DEBUG] Received request - Method: ~p, Path: ~p, Version: ~p~n", [Method, Path, Version]),
            handle_request(Socket, Method, Path);
        {error, Reason} ->
            io:format("[ERROR] Failed to receive HTTP request: ~p~n", [Reason])
    end.

handle_request(Socket, 'GET', {abs_path, <<"/health">>}) ->
    Response = <<"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK">>,
    gen_tcp:send(Socket, Response),
    gen_tcp:close(Socket);

handle_request(Socket, 'GET', {abs_path, <<"/ws">>}) ->
    inet:setopts(Socket, [{packet, raw}]),
    io:format("[GATEWAY] WebSocket handshake incoming on raw stream.~n"),
    gen_tcp:close(Socket);

handle_request(Socket, _Method, _Path) ->
    NotFound = <<"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found">>,
    gen_tcp:send(Socket, NotFound),
    gen_tcp:close(Socket).