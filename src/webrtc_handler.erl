-module(webrtc_handler).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([
  create_broadcast/2,
  end_broadcast/1,
  add_viewer/2,
  remove_viewer/2,
  send_ice_candidate/3,
  send_sdp_answer/2,
  get_broadcast_state/1,
  get_active_viewers/1
]).

-define(SERVER, ?MODULE).

-record(broadcast, {
  stream_id :: binary(),
  broadcaster_id :: binary(),
  status :: atom(),
  start_time :: integer(),
  viewer_count :: integer(),
  viewers = #{} :: map(),
  sdp_offer :: binary() | undefined,
  ice_candidates = [] :: list()
}).

-record(viewer, {
  viewer_id :: binary(),
  stream_id :: binary(),
  connected_at :: integer(),
  sdp_answer :: binary() | undefined,
  ice_candidates = [] :: list(),
  connection_status :: atom()
}).

-record(state, {
  broadcasts = #{} :: map(),
  viewers = #{} :: map(),
  rabbit_channel :: pid() | undefined
}).

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
  {ok, Channel} = rabbit_channel:get_channel(),
  {ok, #state{rabbit_channel = Channel}}.

handle_call({create_broadcast, StreamId, BroadcasterId}, _From, State) ->
  Broadcast = #broadcast{
    stream_id = StreamId,
    broadcaster_id = BroadcasterId,
    status = waiting_for_sdp,
    start_time = erlang:system_time(millisecond),
    viewer_count = 0
  },
  NewState = State#state{broadcasts = maps:put(StreamId, Broadcast, State#state.broadcasts)},
  publish_event(<<"broadcast.created">>, #{
    stream_id => StreamId,
    broadcaster_id => BroadcasterId,
    timestamp => erlang:system_time(millisecond)
  }, State#state.rabbit_channel),
  {reply, {ok, StreamId}, NewState};

handle_call({end_broadcast, StreamId}, _From, State) ->
  case maps:get(StreamId, State#state.broadcasts, undefined) of
    undefined ->
      {reply, {error, broadcast_not_found}, State};
    Broadcast ->
      Viewers = maps:get(StreamId, State#state.viewers, #{}),
      NewBroadcasts = maps:remove(StreamId, State#state.broadcasts),
      NewViewers = maps:without(maps:keys(Viewers), State#state.viewers),
      publish_event(<<"broadcast.ended">>, #{
        stream_id => StreamId,
        viewer_count => map_size(Viewers),
        duration => erlang:system_time(millisecond) - Broadcast#broadcast.start_time,
        timestamp => erlang:system_time(millisecond)
      }, State#state.rabbit_channel),
      {reply, ok, State#state{broadcasts = NewBroadcasts, viewers = NewViewers}}
  end;

handle_call({add_viewer, StreamId, ViewerId}, _From, State) ->
  case maps:get(StreamId, State#state.broadcasts, undefined) of
    undefined ->
      {reply, {error, broadcast_not_found}, State};
    Broadcast ->
      Viewer = #viewer{
        viewer_id = ViewerId,
        stream_id = StreamId,
        connected_at = erlang:system_time(millisecond),
        connection_status = connecting
      },
      ViewerKey = <<StreamId/binary, ":", ViewerId/binary>>,
      NewViewers = maps:put(ViewerKey, Viewer, State#state.viewers),
      UpdatedBroadcast = Broadcast#broadcast{
        viewer_count = Broadcast#broadcast.viewer_count + 1,
        viewers = maps:put(ViewerId, Viewer, Broadcast#broadcast.viewers)
      },
      NewBroadcasts = maps:put(StreamId, UpdatedBroadcast, State#state.broadcasts),
      publish_event(<<"viewer.joined">>, #{
        stream_id => StreamId,
        viewer_id => ViewerId,
        total_viewers => UpdatedBroadcast#broadcast.viewer_count,
        timestamp => erlang:system_time(millisecond)
      }, State#state.rabbit_channel),
      {reply, {ok, Broadcast#broadcast.sdp_offer}, State#state{broadcasts = NewBroadcasts, viewers = NewViewers}}
  end;

handle_call({remove_viewer, StreamId, ViewerId}, _From, State) ->
  case maps:get(StreamId, State#state.broadcasts, undefined) of
    undefined ->
      {reply, {error, broadcast_not_found}, State};
    Broadcast ->
      ViewerKey = <<StreamId/binary, ":", ViewerId/binary>>,
      NewViewers = maps:remove(ViewerKey, State#state.viewers),
      UpdatedViewersMap = maps:remove(ViewerId, Broadcast#broadcast.viewers),
      UpdatedBroadcast = Broadcast#broadcast{
        viewer_count = max(0, Broadcast#broadcast.viewer_count - 1),
        viewers = UpdatedViewersMap
      },
      NewBroadcasts = maps:put(StreamId, UpdatedBroadcast, State#state.broadcasts),
      publish_event(<<"viewer.left">>, #{
        stream_id => StreamId,
        viewer_id => ViewerId,
        total_viewers => UpdatedBroadcast#broadcast.viewer_count,
        timestamp => erlang:system_time(millisecond)
      }, State#state.rabbit_channel),
      {reply, ok, State#state{broadcasts = NewBroadcasts, viewers = NewViewers}}
  end;

handle_call({send_sdp_answer, ViewerKey, SdpAnswer}, _From, State) ->
  case maps:get(ViewerKey, State#state.viewers, undefined) of
    undefined ->
      {reply, {error, viewer_not_found}, State};
    Viewer ->
      UpdatedViewer = Viewer#viewer{
        sdp_answer = SdpAnswer,
        connection_status = connected
      },
      NewViewers = maps:put(ViewerKey, UpdatedViewer, State#state.viewers),
      {reply, ok, State#state{viewers = NewViewers}}
  end;

handle_call({send_ice_candidate, ViewerKey, IceCandidate}, _From, State) ->
  case maps:get(ViewerKey, State#state.viewers, undefined) of
    undefined ->
      {reply, {error, viewer_not_found}, State};
    Viewer ->
      UpdatedViewer = Viewer#viewer{
        ice_candidates = [IceCandidate | Viewer#viewer.ice_candidates]
      },
      NewViewers = maps:put(ViewerKey, UpdatedViewer, State#state.viewers),
      {reply, ok, State#state{viewers = NewViewers}}
  end;

handle_call({get_broadcast_state, StreamId}, _From, State) ->
  case maps:get(StreamId, State#state.broadcasts, undefined) of
    undefined ->
      {reply, {error, broadcast_not_found}, State};
    Broadcast ->
      BroadcastState = #{
        stream_id => Broadcast#broadcast.stream_id,
        broadcaster_id => Broadcast#broadcast.broadcaster_id,
        status => Broadcast#broadcast.status,
        start_time => Broadcast#broadcast.start_time,
        viewer_count => Broadcast#broadcast.viewer_count,
        sdp_offer => Broadcast#broadcast.sdp_offer
      },
      {reply, {ok, BroadcastState}, State}
  end;

handle_call({get_active_viewers, StreamId}, _From, State) ->
  case maps:get(StreamId, State#state.broadcasts, undefined) of
    undefined ->
      {reply, {error, broadcast_not_found}, State};
    Broadcast ->
      Viewers = maps:values(Broadcast#broadcast.viewers),
      ActiveViewers = [#{
        viewer_id => V#viewer.viewer_id,
        connected_at => V#viewer.connected_at,
        status => V#viewer.connection_status
      } || V <- Viewers],
      {reply, {ok, ActiveViewers}, State}
  end;

handle_call(Request, _From, State) ->
  logger:warning("Unknown call: ~p", [Request]),
  {reply, {error, unknown_request}, State}.

handle_cast({broadcast_sdp_offer, StreamId, SdpOffer}, State) ->
  case maps:get(StreamId, State#state.broadcasts, undefined) of
    undefined ->
      {noreply, State};
    Broadcast ->
      UpdatedBroadcast = Broadcast#broadcast{
        sdp_offer = SdpOffer,
        status = streaming
      },
      NewBroadcasts = maps:put(StreamId, UpdatedBroadcast, State#state.broadcasts),
      publish_event(<<"broadcast.started">>, #{
        stream_id => StreamId,
        timestamp => erlang:system_time(millisecond)
      }, State#state.rabbit_channel),
      {noreply, State#state{broadcasts = NewBroadcasts}}
  end;

handle_cast({broadcast_ice_candidate, StreamId, IceCandidate}, State) ->
  case maps:get(StreamId, State#state.broadcasts, undefined) of
    undefined ->
      {noreply, State};
    Broadcast ->
      UpdatedBroadcast = Broadcast#broadcast{
        ice_candidates = [IceCandidate | Broadcast#broadcast.ice_candidates]
      },
      NewBroadcasts = maps:put(StreamId, UpdatedBroadcast, State#state.broadcasts),
      {noreply, State#state{broadcasts = NewBroadcasts}}
  end;

handle_cast(Request, State) ->
  logger:warning("Unknown cast: ~p", [Request]),
  {noreply, State}.

handle_info({rabbit_event, Event}, State) ->
  handle_rabbit_event(Event, State),
  {noreply, State};

handle_info(Info, State) ->
  logger:warning("Unknown info: ~p", [Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

create_broadcast(StreamId, BroadcasterId) ->
  gen_server:call(?SERVER, {create_broadcast, StreamId, BroadcasterId}).

end_broadcast(StreamId) ->
  gen_server:call(?SERVER, {end_broadcast, StreamId}).

add_viewer(StreamId, ViewerId) ->
  gen_server:call(?SERVER, {add_viewer, StreamId, ViewerId}).

remove_viewer(StreamId, ViewerId) ->
  gen_server:call(?SERVER, {remove_viewer, StreamId, ViewerId}).

send_ice_candidate(ViewerKey, IceCandidate, Type) ->
  gen_server:call(?SERVER, {send_ice_candidate, ViewerKey, IceCandidate}).

send_sdp_answer(ViewerKey, SdpAnswer) ->
  gen_server:call(?SERVER, {send_sdp_answer, ViewerKey, SdpAnswer}).

get_broadcast_state(StreamId) ->
  gen_server:call(?SERVER, {get_broadcast_state, StreamId}).

get_active_viewers(StreamId) ->
  gen_server:call(?SERVER, {get_active_viewers, StreamId}).

publish_event(EventType, EventData, Channel) ->
  case Channel of
    undefined -> ok;
    _ ->
      Payload = jsx:encode(EventData),
      rabbit_channel:publish(Channel, <<"events">>, EventType, Payload)
  end.

handle_rabbit_event(Event, _State) ->
  logger:info("Received rabbit event: ~p", [Event]).
