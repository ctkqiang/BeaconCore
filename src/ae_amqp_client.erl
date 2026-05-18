-module(ae_amqp_client).
-behaviour(gen_server).

-include_lib("header/logger.hrl").

-export([start_link/0, publish/3, subscribe/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    socket :: gen_tcp:socket() | undefined,
    channel_id = 1 :: integer(),
    subscribers = #{} :: map()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

publish(Exchange, RoutingKey, Payload) ->
    gen_server:call(?MODULE, {publish, Exchange, RoutingKey, Payload}, 5000).

subscribe(Queue, ConsumerPid) ->
    gen_server:call(?MODULE, {subscribe, Queue, ConsumerPid}, 5000).

init([]) ->
    Host = application:get_env(beacon_core, amqp_host, "localhost"),
    Port = application:get_env(beacon_core, amqp_port, 5672),
    User = application:get_env(beacon_core, amqp_user, "guest"),
    Pass = application:get_env(beacon_core, amqp_pass, "guest"),

    case connect_and_handshake(Host, Port, User, Pass) of
        {ok, Socket} ->
            ?LOG_NOTICE("AMQP client connected", #{host => Host, port => Port}),
            {ok, #state{socket = Socket}};
        {error, Reason} ->
            ?LOG_ERROR("AMQP handshake failed", #{reason => Reason}),
            {stop, Reason}
    end.

handle_call({publish, Exchange, RoutingKey, Payload}, _From, State = #state{socket = Socket, channel_id = ChId}) ->
    case publish_internal(Socket, ChId, Exchange, RoutingKey, Payload) of
        ok ->
            {reply, ok, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({subscribe, Queue, ConsumerPid}, _From, State = #state{socket = Socket, channel_id = ChId}) ->
    case subscribe_internal(Socket, ChId, Queue, ConsumerPid) of
        ok ->
            NewSubscribers = (State#state.subscribers)#{Queue => ConsumerPid},
            {reply, ok, State#state{subscribers = NewSubscribers}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, Socket, Data}, State = #state{socket = Socket, subscribers = Subscribers}) ->
    case parse_amqp_frame(Data) of
        {ok, Frame} ->
            case handle_frame(Frame, Subscribers) of
                ok -> {noreply, State};
                {deliver, Queue, Payload} ->
                    case maps:find(Queue, Subscribers) of
                        {ok, Pid} ->
                            Pid ! {amqp_delivery, Queue, Payload},
                            {noreply, State};
                        error ->
                            {noreply, State}
                    end
            end;
        error ->
            {noreply, State}
    end;

handle_info({tcp_closed, _Socket}, State) ->
    ?LOG_ERROR("AMQP connection closed", #{}),
    {stop, connection_closed, State};

handle_info({tcp_error, _Socket, Reason}, State) ->
    ?LOG_ERROR("AMQP socket error", #{reason => Reason}),
    {stop, Reason, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{socket = Socket}) ->
    if Socket =/= undefined -> gen_tcp:close(Socket); true -> ok end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ====================================================================
%% Internal Functions
%% ====================================================================

connect_and_handshake(Host, Port, User, Pass) ->
    case gen_tcp:connect(Host, Port, [binary, {active, true}, {packet, raw}], 5000) of
        {ok, Socket} ->
            case amqp_handshake(Socket, User, Pass) of
                ok -> {ok, Socket};
                Error -> Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

amqp_handshake(Socket, User, Pass) ->
    gen_tcp:send(Socket, <<"AMQP", 0, 0, 9, 1>>),
    case recv_method_frame(Socket) of
        {ok, connection_start, _Props} ->
            StartOk = encode_method_frame(1, connection_start_ok, [
                {table, [{<<"product">>, binary, <<"BeaconCore">>}]},
                {binary, <<"PLAIN">>},
                {binary, encode_plain_auth(User, Pass)},
                {binary, <<"en_US">>}
            ]),
            gen_tcp:send(Socket, StartOk),
            case recv_method_frame(Socket) of
                {ok, connection_tune, _Props} ->
                    TuneOk = encode_method_frame(1, connection_tune_ok, [
                        {short, 2048},
                        {long, 0},
                        {short, 60}
                    ]),
                    gen_tcp:send(Socket, TuneOk),
                    Open = encode_method_frame(1, connection_open, [
                        {binary, <<"/">>},
                        {binary, <<>>},
                        {boolean, false}
                    ]),
                    gen_tcp:send(Socket, Open),
                    case recv_method_frame(Socket) of
                        {ok, connection_open_ok, _} ->
                            declare_topology(Socket);
                        _ ->
                            {error, tune_handshake_failed}
                    end;
                _ ->
                    {error, tune_failed}
            end;
        _ ->
            {error, handshake_failed}
    end.

declare_topology(Socket) ->
    case channel_open(Socket) of
        {ok, _} ->
            case exchange_declare(Socket) of
                ok ->
                    case queue_declare(Socket) of
                        ok ->
                            queue_bind(Socket);
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

channel_open(Socket) ->
    Open = encode_method_frame(1, channel_open, [{binary, <<>>}]),
    gen_tcp:send(Socket, Open),
    recv_method_frame(Socket).

exchange_declare(Socket) ->
    Declare = encode_method_frame(1, exchange_declare, [
        {short, 0},
        {binary, <<"notifications">>},
        {binary, <<"topic">>},
        {boolean, false},
        {boolean, true},
        {boolean, false},
        {boolean, false},
        {boolean, false},
        {table, []}
    ]),
    gen_tcp:send(Socket, Declare),
    case recv_method_frame(Socket) of
        {ok, exchange_declare_ok, _} -> ok;
        _ -> {error, exchange_declare_failed}
    end.

queue_declare(Socket) ->
    Declare = encode_method_frame(1, queue_declare, [
        {short, 0},
        {binary, <<"notifications.dispatch">>},
        {boolean, false},
        {boolean, true},
        {boolean, false},
        {boolean, false},
        {boolean, false},
        {table, []}
    ]),
    gen_tcp:send(Socket, Declare),
    case recv_method_frame(Socket) of
        {ok, queue_declare_ok, _} -> ok;
        _ -> {error, queue_declare_failed}
    end.

queue_bind(Socket) ->
    Bind = encode_method_frame(1, queue_bind, [
        {short, 0},
        {binary, <<"notifications.dispatch">>},
        {binary, <<"notifications">>},
        {binary, <<"notifications.#">>},
        {boolean, false},
        {table, []}
    ]),
    gen_tcp:send(Socket, Bind),
    case recv_method_frame(Socket) of
        {ok, queue_bind_ok, _} -> ok;
        _ -> {error, queue_bind_failed}
    end.

publish_internal(Socket, ChannelId, Exchange, RoutingKey, Payload) ->
    Publish = encode_method_frame(ChannelId, basic_publish, [
        {short, 0},
        {binary, Exchange},
        {binary, RoutingKey},
        {boolean, false},
        {boolean, false}
    ]),
    gen_tcp:send(Socket, Publish),
    Header = encode_content_header_frame(ChannelId, byte_size(Payload)),
    gen_tcp:send(Socket, Header),
    Body = encode_body_frame(ChannelId, Payload),
    gen_tcp:send(Socket, Body),
    ok.

subscribe_internal(Socket, ChannelId, Queue, _ConsumerPid) ->
    Consume = encode_method_frame(ChannelId, basic_consume, [
        {short, 0},
        {binary, Queue},
        {binary, <<"consumer_", (atom_to_binary(node(), utf8))/binary>>},
        {boolean, false},
        {boolean, true},
        {boolean, false},
        {boolean, false},
        {table, []}
    ]),
    gen_tcp:send(Socket, Consume),
    case recv_method_frame(Socket) of
        {ok, basic_consume_ok, _} -> ok;
        _ -> {error, consume_failed}
    end.

recv_method_frame(Socket) ->
    case gen_tcp:recv(Socket, 8, 5000) of
        {ok, FrameHeader} ->
            <<Type:8, ChannelId:16, Size:32>> = FrameHeader,
            case Type of
                1 ->
                    case gen_tcp:recv(Socket, Size + 1, 5000) of
                        {ok, MethodData} ->
                            <<Payload:Size/binary, 0xCE>> = MethodData,
                            decode_method(Payload);
                        Error ->
                            Error
                    end;
                _ ->
                    {error, invalid_frame_type}
            end;
        Error ->
            Error
    end.

decode_method(<<ClassId:16, MethodId:16, Rest/binary>>) ->
    case {ClassId, MethodId} of
        {10, 10} -> {ok, connection_start, Rest};
        {10, 31} -> {ok, connection_tune, Rest};
        {10, 41} -> {ok, connection_open_ok, Rest};
        {20, 11} -> {ok, channel_open_ok, Rest};
        {40, 11} -> {ok, exchange_declare_ok, Rest};
        {50, 11} -> {ok, queue_declare_ok, Rest};
        {50, 21} -> {ok, queue_bind_ok, Rest};
        {60, 11} -> {ok, basic_consume_ok, Rest};
        {60, 60} -> {ok, basic_deliver, Rest};
        {8, 0} -> {ok, heartbeat, Rest};
        _ -> {error, unknown_method}
    end.

handle_frame({ok, heartbeat, _}, _Subscribers) ->
    ok;

handle_frame({ok, basic_deliver, _}, _Subscribers) ->
    ok;

handle_frame(_, _) ->
    ok.

parse_amqp_frame(_Data) ->
    error.

encode_method_frame(ChannelId, Method, Args) ->
    {ClassId, MethodId} = method_id(Method),
    MethodBody = <<ClassId:16, MethodId:16, (encode_args(Args))/binary>>,
    Size = byte_size(MethodBody),
    <<1:8, ChannelId:16, Size:32, MethodBody/binary, 0xCE:8>>.

encode_content_header_frame(ChannelId, BodySize) ->
    Header = <<60:16, 0:16, 0:16, BodySize:64>>,
    Size = byte_size(Header),
    <<2:8, ChannelId:16, Size:32, Header/binary, 0xCE:8>>.

encode_body_frame(ChannelId, Payload) ->
    Size = byte_size(Payload),
    <<3:8, ChannelId:16, Size:32, Payload/binary, 0xCE:8>>.

method_id(connection_start_ok) -> {10, 11};
method_id(connection_tune_ok) -> {10, 31};
method_id(connection_open) -> {10, 40};
method_id(channel_open) -> {20, 10};
method_id(exchange_declare) -> {40, 10};
method_id(queue_declare) -> {50, 10};
method_id(queue_bind) -> {50, 20};
method_id(basic_publish) -> {60, 40};
method_id(basic_consume) -> {60, 20};
method_id(_) -> {0, 0}.

encode_args([]) ->
    <<>>;
encode_args([{short, V} | Rest]) ->
    <<V:16, (encode_args(Rest))/binary>>;
encode_args([{long, V} | Rest]) ->
    <<V:32, (encode_args(Rest))/binary>>;
encode_args([{binary, V} | Rest]) ->
    <<(byte_size(V)):32, V/binary, (encode_args(Rest))/binary>>;
encode_args([{boolean, V} | Rest]) ->
    B = if V -> 1; true -> 0 end,
    <<B:8, (encode_args(Rest))/binary>>;
encode_args([{table, _T} | Rest]) ->
    <<0:32, (encode_args(Rest))/binary>>;
encode_args([_Unknown | Rest]) ->
    encode_args(Rest).

encode_plain_auth(User, Pass) ->
    UserBin = list_to_binary(User),
    PassBin = list_to_binary(Pass),
    <<0, UserBin/binary, 0, PassBin/binary>>.
