-module(network_gateway).
-behaviour(gen_server).

-export([start_link/0, get_health/0]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_health() ->
    gen_server:call(?MODULE, check_health).


init([]) ->
    Port = application:get_env(beacon_core, http_port, 8080),
    SocketOptions = [binary, {packet, http}, {reuseaddr, true}, {active, false}],
    
    case gen_tcp:listen(Port, SocketOptions) of
        {ok, ListenSocket} ->
            %% Signal the process to immediately jump into its non-blocking accept loop
            self() ! accept_next,
            {ok, #state{listen_socket = ListenSocket}};
        {error, Reason} ->
            error_logger:error_msg("Gateway failed to bind to port ~p: ~p~n", [Port, Reason]),
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
            handle_client(ClientSocket),
            self() ! accept_next,
            {noreply, State};
        {error, timeout} ->
            self() ! accept_next,
            {noreply, State};
        {error, _Closed} ->
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
        {ok, {http_request, 'GET', {abs_path, <<"/health">>}, _Version}} ->
            %% Direct match to our health validation step
            Response = <<"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK">>,
            gen_tcp:send(Socket, Response),
            gen_tcp:close(Socket);

        {ok, {http_request, 'GET', {abs_path, <<"/ws">>}, _Version}} ->
            %% Upgrade protocol flag detected for persistent downstream real-time WebSockets
            inet:setopts(Socket, [{packet, raw}]),
            io:format("[GATEWAY] WebSocket handshake incoming on raw stream.~n"),
            
            %% Hand over execution path to your ae_public_ws engine...
            gen_tcp:close(Socket);

        _Fallback ->
            %% Drop anything else securely with a 404, duh.....
            NotFound = <<"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found">>,
            gen_tcp:send(Socket, NotFound),
            gen_tcp:close(Socket)
    end.