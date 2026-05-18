-module(ae_routing_engine).
-behaviour(gen_server).

-include_lib("header/logger.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {amqp_pid, consumer_tag}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ?LOG_NOTICE("Routing engine initializing", #{}),
    case ae_amqp_client:start_link() of
        {ok, AmqpPid} ->
            ?LOG_INFO("AMQP client started", #{pid => AmqpPid}),
            case ae_amqp_client:subscribe(<<"notifications.dispatch">>, self()) of
                {ok, ConsumerTag} ->
                    ?LOG_NOTICE("Subscribed to RabbitMQ queue", #{consumer_tag => ConsumerTag}),
                    {ok, #state{amqp_pid = AmqpPid, consumer_tag = ConsumerTag}};
                {error, Reason} ->
                    ?LOG_ERROR("Failed to subscribe to queue", #{reason => Reason}),
                    {stop, Reason}
            end;
        {error, Reason} ->
            ?LOG_ERROR("Failed to start AMQP client", #{reason => Reason}),
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({amqp_delivery, RoutingKey, Payload}, State) ->
    io:format("[NOTICE] Message received from RabbitMQ | RoutingKey: ~p, PayloadSize: ~p bytes~n",
              [RoutingKey, byte_size(Payload)]),
    dispatch_message(RoutingKey, Payload),
    {noreply, State};

handle_info({amqp_delivery, RoutingKey, Payload, DeliveryTag}, State) ->
    io:format("[NOTICE] Message received from RabbitMQ | RoutingKey: ~p, PayloadSize: ~p bytes~n",
              [RoutingKey, byte_size(Payload)]),
    dispatch_message(RoutingKey, Payload),
    {noreply, State};

handle_info(Info, State) ->
    io:format("[DEBUG] Routing engine received unknown info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, #state{amqp_pid = AmqpPid}) ->
    case is_pid(AmqpPid) of
        true -> gen_server:stop(AmqpPid);
        false -> ok
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

dispatch_message(RoutingKey, Payload) ->
    case parse_routing_key(RoutingKey) of
        {ok, FilterType, FilterValue} ->
            io:format("[DEBUG] Parsed routing key | Type: ~p, Value: ~p~n", [FilterType, FilterValue]),
            resolve_and_dispatch(FilterType, FilterValue, Payload);
        {error, Reason} ->
            io:format("[WARN] Failed to parse routing key ~p: ~p~n", [RoutingKey, Reason])
    end.

parse_routing_key(<<"notifications.broadcast">>) ->
    {ok, broadcast, <<"all">>};

parse_routing_key(<<"notifications.channel.", ChannelName/binary>>) ->
    {ok, channel, ChannelName};

parse_routing_key(<<"notifications.segment.", SegmentName/binary>>) ->
    {ok, segment, SegmentName};

parse_routing_key(<<"notifications.user.", UserId/binary>>) ->
    {ok, user_id, UserId};

parse_routing_key(Key) ->
    {error, {unknown_routing_key, Key}}.

resolve_and_dispatch(broadcast, _FilterValue, Payload) ->
    io:format("[INFO] Broadcast dispatch | Sending to all connected users~n"),
    dispatch_to_scope(notification_scope, Payload);

resolve_and_dispatch(channel, ChannelName, Payload) ->
    io:format("[INFO] Channel dispatch | Channel: ~p~n", [ChannelName]),
    dispatch_to_scope({channel, ChannelName}, Payload);

resolve_and_dispatch(segment, SegmentName, Payload) ->
    io:format("[INFO] Segment dispatch | Segment: ~p~n", [SegmentName]),
    dispatch_to_scope({segment, SegmentName}, Payload);

resolve_and_dispatch(user_id, UserId, Payload) ->
    io:format("[INFO] User dispatch | UserId: ~p~n", [UserId]),
    dispatch_to_user(UserId, Payload).

dispatch_to_scope(Scope, Payload) ->
    try
        Members = pg:get_members(notification_scope, Scope),
        io:format("[DEBUG] Found ~p members in scope ~p~n", [length(Members), Scope]),
        dispatch_to_pids(Members, Payload)
    catch
        _:Error ->
            io:format("[WARN] Error getting scope members: ~p~n", [Error])
    end.

dispatch_to_user(UserId, Payload) ->
    try
        Members = pg:get_members(notification_scope, {user, UserId}),
        case Members of
            [] ->
                io:format("[NOTICE] User ~p offline, would queue for VAPID push~n", [UserId]);
            _ ->
                io:format("[DEBUG] User ~p online with ~p connection(s)~n", [UserId, length(Members)]),
                dispatch_to_pids(Members, Payload)
        end
    catch
        _:Error ->
            io:format("[WARN] Error resolving user ~p: ~p~n", [UserId, Error])
    end.

dispatch_to_pids([], _Payload) ->
    ok;

dispatch_to_pids([Pid | Rest], Payload) ->
    case is_process_alive(Pid) of
        true ->
            Pid ! {send_msg, Payload},
            io:format("[DEBUG] Message dispatched to process ~p~n", [Pid]),
            dispatch_to_pids(Rest, Payload);
        false ->
            io:format("[WARN] Target process ~p is dead, skipping~n", [Pid]),
            dispatch_to_pids(Rest, Payload)
    end.
