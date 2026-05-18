-module(ae_admin_handler).

-include_lib("header/logger.hrl").

-export([handle_request/4]).

handle_request(Socket, 'POST', <<"/v1/admin/broadcast", _/binary>>, Body) ->
    handle_broadcast(Socket, Body);

handle_request(Socket, _Method, _Path, _Body) ->
    NotFound = <<"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found">>,
    gen_tcp:send(Socket, NotFound),
    gen_tcp:close(Socket).

handle_broadcast(Socket, Body) ->
    io:format("[DEBUG] Broadcast body received | Size: ~p bytes~n", [byte_size(Body)]),
    case parse_json_broadcast(Body) of
        {ok, BroadcastType, Payload, FilterParams} ->
            io:format("[INFO] Broadcast parsed | Type: ~p, Filter: ~p~n", [BroadcastType, FilterParams]),
            case write_audit_log(BroadcastType, FilterParams) of
                ok ->
                    io:format("[DEBUG] Audit log written~n"),
                    case publish_to_rabbitmq(BroadcastType, Payload, FilterParams) of
                        ok ->
                            io:format("[NOTICE] Message published to RabbitMQ | RoutingKey: ~p~n", [derive_routing_key(BroadcastType, FilterParams)]),
                            send_202_accepted(Socket);
                        {error, Reason} ->
                            ?LOG_ERROR("Failed to publish to RabbitMQ", #{reason => Reason}),
                            io:format("[ERROR] RabbitMQ publish failed: ~p~n", [Reason]),
                            send_500(Socket)
                    end;
                {error, Reason} ->
                    ?LOG_ERROR("Failed to write audit log", #{reason => Reason}),
                    io:format("[ERROR] Audit log write failed: ~p~n", [Reason]),
                    send_500(Socket)
            end;
        {error, Reason} ->
            ?LOG_WARN("Invalid broadcast JSON", #{reason => Reason}),
            io:format("[WARN] Invalid JSON in broadcast: ~p~n", [Reason]),
            send_400(Socket)
    end.

parse_json_broadcast(Body) ->
    try
        {ok, Type} = extract_json_field(Body, <<"type">>),
        {ok, Payload} = extract_json_field(Body, <<"payload">>),
        {ok, Filter} = extract_json_field(Body, <<"filter">>),
        {ok, Type, Payload, Filter}
    catch
        _:_ ->
            {error, json_parse_failed}
    end.

extract_json_field(Body, FieldName) ->
    case binary:match(Body, <<"\"", FieldName/binary, "\"">>) of
        {Start, _Len} ->
            SearchStart = Start + byte_size(FieldName) + 2,
            case binary:match(Body, <<":">>, [{scope, {SearchStart, byte_size(Body) - SearchStart}}]) of
                {ColonPos, _} ->
                    ContentStart = ColonPos + 1,
                    extract_json_value(Body, ContentStart);
                nomatch ->
                    {error, missing_colon}
            end;
        nomatch ->
            {error, field_not_found}
    end.

extract_json_value(Body, Start) ->
    SkipSpaces = binary:match(Body, <<>>, [{scope, {Start, byte_size(Body) - Start}}]),
    ActualStart = case SkipSpaces of
        {Pos, _} -> Pos;
        nomatch -> Start
    end,
    case binary:at(Body, ActualStart) of
        $" ->
            extract_json_string(Body, ActualStart + 1);
        ${ ->
            extract_json_object(Body, ActualStart);
        $[ ->
            extract_json_array(Body, ActualStart);
        _ ->
            {error, invalid_json_value}
    end.

extract_json_string(Body, Start) ->
    case binary:match(Body, <<"\"">>, [{scope, {Start, byte_size(Body) - Start}}]) of
        {EndPos, _} ->
            Value = binary:part(Body, Start, EndPos - Start),
            {ok, Value};
        nomatch ->
            {error, unterminated_string}
    end.

extract_json_object(Body, Start) ->
    case find_matching_brace(Body, Start, 1, Start + 1) of
        {ok, EndPos} ->
            Value = binary:part(Body, Start, EndPos - Start + 1),
            {ok, Value};
        error ->
            {error, unterminated_object}
    end.

extract_json_array(Body, Start) ->
    case find_matching_bracket(Body, Start, 1, Start + 1) of
        {ok, EndPos} ->
            Value = binary:part(Body, Start, EndPos - Start + 1),
            {ok, Value};
        error ->
            {error, unterminated_array}
    end.

find_matching_brace(Body, _OpenPos, 0, EndPos) ->
    {ok, EndPos - 1};

find_matching_brace(Body, _OpenPos, _Depth, Pos) when Pos >= byte_size(Body) ->
    error;

find_matching_brace(Body, OpenPos, Depth, Pos) ->
    case binary:at(Body, Pos) of
        ${ -> find_matching_brace(Body, OpenPos, Depth + 1, Pos + 1);
        $} -> find_matching_brace(Body, OpenPos, Depth - 1, Pos + 1);
        _ -> find_matching_brace(Body, OpenPos, Depth, Pos + 1)
    end.

find_matching_bracket(Body, _OpenPos, 0, EndPos) ->
    {ok, EndPos - 1};

find_matching_bracket(Body, _OpenPos, _Depth, Pos) when Pos >= byte_size(Body) ->
    error;

find_matching_bracket(Body, OpenPos, Depth, Pos) ->
    case binary:at(Body, Pos) of
        $[ -> find_matching_bracket(Body, OpenPos, Depth + 1, Pos + 1);
        $] -> find_matching_bracket(Body, OpenPos, Depth - 1, Pos + 1);
        _ -> find_matching_bracket(Body, OpenPos, Depth, Pos + 1)
    end.

write_audit_log(BroadcastType, FilterParams) ->
    Timestamp = format_iso8601_timestamp(),
    LogEntry = iolist_to_binary([
        <<"INSERT INTO admin_audit_logs (timestamp, broadcast_type, filter_params) VALUES ('">>,
        Timestamp,
        <<"', '">>,
        BroadcastType,
        <<"', '">>,
        FilterParams,
        <<"');">>
    ]),
    ?LOG_DEBUG("Audit log", #{entry => LogEntry}),
    ok.

publish_to_rabbitmq(BroadcastType, Payload, FilterParams) ->
    RoutingKey = derive_routing_key(BroadcastType, FilterParams),
    case ae_amqp_client:publish(<<"notifications">>, RoutingKey, Payload) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

derive_routing_key(<<"broadcast">>, _FilterParams) ->
    <<"notifications.broadcast">>;

derive_routing_key(<<"channel">>, ChannelName) ->
    <<"notifications.channel.", ChannelName/binary>>;

derive_routing_key(<<"segment">>, SegmentName) ->
    <<"notifications.segment.", SegmentName/binary>>;

derive_routing_key(<<"id">>, UserId) ->
    <<"notifications.user.", UserId/binary>>;

derive_routing_key(_Type, _Params) ->
    <<"notifications.broadcast">>.

format_iso8601_timestamp() ->
    {Date, Time} = calendar:universal_time(),
    DateStr = format_date(Date),
    TimeStr = format_time(Time),
    iolist_to_binary([DateStr, <<"T">>, TimeStr, <<"Z">>]).

format_date({Y, M, D}) ->
    io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D]).

format_time({H, Mi, S}) ->
    io_lib:format("~2..0B:~2..0B:~2..0B", [H, Mi, S]).

send_202_accepted(Socket) ->
    Body = <<"{\r\n  \"status\": \"dispatched\"\r\n}">>,
    ContentLength = integer_to_binary(byte_size(Body)),
    Response = <<"HTTP/1.1 202 Accepted\r\n",
                 "Content-Type: application/json\r\n",
                 "Content-Length: ", ContentLength/binary, "\r\n",
                 "Connection: close\r\n",
                 "\r\n">>,
    gen_tcp:send(Socket, Response),
    gen_tcp:send(Socket, Body),
    gen_tcp:close(Socket).

send_400(Socket) ->
    Body = <<"{\r\n  \"error\": \"Invalid request\"\r\n}">>,
    ContentLength = integer_to_binary(byte_size(Body)),
    Response = <<"HTTP/1.1 400 Bad Request\r\n",
                 "Content-Type: application/json\r\n",
                 "Content-Length: ", ContentLength/binary, "\r\n",
                 "Connection: close\r\n",
                 "\r\n">>,
    gen_tcp:send(Socket, Response),
    gen_tcp:send(Socket, Body),
    gen_tcp:close(Socket).

send_500(Socket) ->
    Body = <<"{\r\n  \"error\": \"Internal server error\"\r\n}">>,
    ContentLength = integer_to_binary(byte_size(Body)),
    Response = <<"HTTP/1.1 500 Internal Server Error\r\n",
                 "Content-Type: application/json\r\n",
                 "Content-Length: ", ContentLength/binary, "\r\n",
                 "Connection: close\r\n",
                 "\r\n">>,
    gen_tcp:send(Socket, Response),
    gen_tcp:send(Socket, Body),
    gen_tcp:close(Socket).
