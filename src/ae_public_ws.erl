-module(ae_public_ws).

-include_lib("header/logger.hrl").

-export([handle_upgrade/3]).

-define(WS_MAGIC, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").

handle_upgrade(Socket, Headers, QueryString) ->
    case extract_header(Headers, "sec-websocket-key") of
        {ok, ClientKey} ->
            case verify_headers(Headers) of
                ok ->
                    AcceptKey = compute_accept_key(ClientKey),
                    send_upgrade_response(Socket, AcceptKey),
                    UserId = extract_user_id(QueryString),
                    pg:join(notification_scope, {user, UserId}, self()),
                    ?LOG_DEBUG("WebSocket user registered", #{user_id => UserId}),
                    ws_loop(Socket, UserId);
                error ->
                    send_400(Socket)
            end;
        error ->
            send_400(Socket)
    end.

ws_loop(Socket, UserId) ->
    case gen_tcp:recv(Socket, 2, 5000) of
        {ok, <<FIN:1, _RSV:3, Opcode:4, Mask:1, PayloadLen:7>>} ->
            case recv_frame_payload(Socket, Mask, PayloadLen) of
                {ok, Payload} ->
                    case handle_frame(Socket, Opcode, Payload, UserId) of
                        continue -> ws_loop(Socket, UserId);
                        close -> gen_tcp:close(Socket)
                    end;
                {error, _} ->
                    gen_tcp:close(Socket)
            end;
        {error, timeout} ->
            ws_loop(Socket, UserId);
        {error, _} ->
            gen_tcp:close(Socket)
    after
        infinity ->
            receive
                {send_msg, MessagePayload} ->
                    Frame = encode_text_frame(MessagePayload),
                    gen_tcp:send(Socket, Frame),
                    ws_loop(Socket, UserId);
                {close, _} ->
                    gen_tcp:close(Socket)
            after 5000 ->
                ws_loop(Socket, UserId)
            end
    end.

recv_frame_payload(Socket, 0, PayloadLen) ->
    gen_tcp:recv(Socket, PayloadLen, 5000);

recv_frame_payload(Socket, 1, PayloadLen) when PayloadLen < 126 ->
    case gen_tcp:recv(Socket, 4, 5000) of
        {ok, MaskKey} ->
            case gen_tcp:recv(Socket, PayloadLen, 5000) of
                {ok, MaskedPayload} ->
                    Payload = unmask_payload(MaskedPayload, MaskKey),
                    {ok, Payload};
                Error ->
                    Error
            end;
        Error ->
            Error
    end;

recv_frame_payload(Socket, 1, 126) ->
    case gen_tcp:recv(Socket, 2, 5000) of
        {ok, <<RealLen:16>>} ->
            case gen_tcp:recv(Socket, 4, 5000) of
                {ok, MaskKey} ->
                    case gen_tcp:recv(Socket, RealLen, 5000) of
                        {ok, MaskedPayload} ->
                            Payload = unmask_payload(MaskedPayload, MaskKey),
                            {ok, Payload};
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end;

recv_frame_payload(Socket, 1, 127) ->
    case gen_tcp:recv(Socket, 8, 5000) of
        {ok, <<RealLen:64>>} ->
            case gen_tcp:recv(Socket, 4, 5000) of
                {ok, MaskKey} ->
                    case gen_tcp:recv(Socket, RealLen, 5000) of
                        {ok, MaskedPayload} ->
                            Payload = unmask_payload(MaskedPayload, MaskKey),
                            {ok, Payload};
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

handle_frame(_Socket, 1, Payload, _UserId) ->
    io:format("[DEBUG] WebSocket received text: ~s~n", [Payload]),
    continue;

handle_frame(_Socket, 2, Payload, _UserId) ->
    io:format("[DEBUG] WebSocket received binary: ~p~n", [Payload]),
    continue;

handle_frame(Socket, 9, _Payload, _UserId) ->
    PongFrame = <<1:1, 0:3, 10:4, 0:1, 0:7>>,
    gen_tcp:send(Socket, PongFrame),
    continue;

handle_frame(_Socket, 8, _Payload, _UserId) ->
    close;

handle_frame(_Socket, _Opcode, _Payload, _UserId) ->
    continue.

encode_text_frame(Payload) ->
    PayloadSize = byte_size(Payload),
    if
        PayloadSize < 126 ->
            <<1:1, 0:3, 1:4, 0:1, PayloadSize:7, Payload/binary>>;
        PayloadSize < 65536 ->
            <<1:1, 0:3, 1:4, 0:1, 126:7, PayloadSize:16, Payload/binary>>;
        true ->
            <<1:1, 0:3, 1:4, 0:1, 127:7, PayloadSize:64, Payload/binary>>
    end.

unmask_payload(MaskedPayload, MaskKey) ->
    unmask_payload_loop(MaskedPayload, MaskKey, 0, <<>>).

unmask_payload_loop(<<>>, _MaskKey, _Idx, Acc) ->
    Acc;

unmask_payload_loop(<<Byte:8, Rest/binary>>, MaskKey, Idx, Acc) ->
    MaskIdx = Idx rem 4,
    <<_:MaskIdx/bytes, MaskByte:8, _/bytes>> = MaskKey,
    UnmaskedByte = Byte bxor MaskByte,
    unmask_payload_loop(Rest, MaskKey, Idx + 1, <<Acc/binary, UnmaskedByte:8>>).

compute_accept_key(ClientKey) ->
    Key = <<ClientKey/binary, ?WS_MAGIC>>,
    SHA = crypto:hash(sha, Key),
    base64:encode(SHA).

verify_headers(Headers) ->
    HasUpgrade = lists:any(fun({Name, Value}) ->
        string:lowercase(Name) =:= "upgrade" andalso string:lowercase(Value) =:= "websocket"
    end, Headers),
    HasConnection = lists:any(fun({Name, Value}) ->
        string:lowercase(Name) =:= "connection" andalso string:find(string:lowercase(Value), "upgrade") =/= nomatch
    end, Headers),
    case HasUpgrade andalso HasConnection of
        true -> ok;
        false -> error
    end.

extract_header(Headers, Name) ->
    LowerName = string:lowercase(Name),
    case lists:keyfind(LowerName, 1, Headers) of
        {_, Value} -> {ok, Value};
        false -> error
    end.

extract_user_id(QueryString) ->
    case string:find(QueryString, "user_id=") of
        nomatch -> <<"anonymous">>;
        Rest ->
            Tail = string:slice(Rest, 8),
            case string:find(Tail, "&") of
                nomatch -> list_to_binary(Tail);
                _ -> list_to_binary(string:slice(Tail, 0, string:find(Tail, "&") - 1))
            end
    end.

send_upgrade_response(Socket, AcceptKey) ->
    Response = <<"HTTP/1.1 101 Switching Protocols\r\n",
                 "Upgrade: websocket\r\n",
                 "Connection: Upgrade\r\n",
                 "Sec-WebSocket-Accept: ", AcceptKey/binary, "\r\n",
                 "\r\n">>,
    gen_tcp:send(Socket, Response).

send_400(Socket) ->
    Response = <<"HTTP/1.1 400 Bad Request\r\n",
                 "Content-Length: 11\r\n",
                 "\r\n",
                 "Bad Request">>,
    gen_tcp:send(Socket, Response),
    gen_tcp:close(Socket).
