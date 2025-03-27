-module(ro2erl_bridge_server).

-moduledoc """
Main bridge server

This module is responsible for:
1. Registering with the hub
2. Processing ROS2 messages
3. Forwarding messages to the hub
4. Receiving messages from the hub and dispatching them locally
""".

-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").


%=== EXPORTS ===================================================================

%% API functions
-export([start_link/2]).
-export([attach/1, attach/2]).
-export([detach/1, detach/2]).
-export([dispatch/1, dispatch/2]).
-export([is_connected/0, is_connected/1]).
-export([get_metrics/0, get_metrics/1]).
-export([set_topic_bandwidth/2, set_topic_bandwidth/3]).

%% Behaviour gen_statem callback functions
-export([callback_mode/0]).
-export([init/1]).
-export([terminate/3]).
-export([code_change/4]).

%% State functions
-export([disconnected/3]).
-export([connected/3]).

%% Temporary exports until these function are used
-export([update_dispatch_metrics/2]).
-export([update_forward_metrics/2]).


%=== MACROS ====================================================================

-define(SERVER, ?MODULE).


%=== TYPES =====================================================================

-record(hub, {
    mon_ref :: reference()
    % Future fields for filtering rules will go here
}).

-record(topic, {
    filterable = false :: boolean(),
    dispatch_last_update :: undefined | non_neg_integer(),
    forward_last_update :: undefined | non_neg_integer(),
    bytes_dispatched = 0 :: non_neg_integer(),
    msgs_dispatched = 0.0 :: float(),
    bytes_forwarded = 0 :: non_neg_integer(),
    msgs_forwarded = 0.0 :: float(),
    limit = infinity :: non_neg_integer() | infinity
}).

-record(data, {
    hubs = #{} :: #{pid() => #hub{}},  % Map of hub pids to hub records
    hub_mod :: module(),               % Module to use for hub communication
    local_callback :: undefined | {module(), atom(), list()},
    bridge_id :: undefined | binary(),
    topics = #{} :: #{Name ::binary() => #topic{}},
    msg_processor :: fun((term()) -> {topic, binary(), boolean(), non_neg_integer()})
}).


%=== API FUNCTIONS =============================================================

start_link(HubMod, MsgProcessor) ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [HubMod, MsgProcessor], []).

-doc """
Same as calling attach(?SERVER, HubPid).
""".
-spec attach(pid()) -> ok | {error, already_attached}.
attach(HubPid) when is_pid(HubPid) ->
    attach(?SERVER, HubPid).

-doc """
Attach this bridge to a hub manager process using a specific server.

### Example:
```
> ro2erl_bridge_server:attach(ServerRef, HubPid).
ok
```
""".
-spec attach(ServerRef :: pid() | atom(), HubPid :: pid()) -> ok | {error, already_attached}.
attach(ServerRef, HubPid) when is_pid(HubPid) ->
    gen_statem:call(ServerRef, {attach, HubPid}).

-doc """
Same as calling detach(?SERVER, HubPid).
""".
-spec detach(pid()) -> ok | {error, not_attached}.
detach(HubPid) when is_pid(HubPid) ->
    detach(?SERVER, HubPid).

-doc """
Detach this bridge from a specific hub manager process.

### Example:
```
> ro2erl_bridge_server:detach(ServerRef, HubPid).
ok
```
""".
-spec detach(ServerRef :: pid() | atom(), HubPid :: pid()) -> ok | {error, not_attached}.
detach(ServerRef, HubPid) when is_pid(HubPid) ->
    gen_statem:call(ServerRef, {detach, HubPid}).

-doc """
Same as calling dispatch(?SERVER, Message).
""".
-spec dispatch(term()) -> ok.
dispatch(Message) ->
    dispatch(?SERVER, Message).

-doc """
Process already parsed ROS2 message from local network using a specific server.

### Example:
```
> ro2erl_bridge_server:dispatch(ServerRef, Message).
ok
```
""".
-spec dispatch(ServerRef :: pid() | atom(), Message :: term()) -> ok.
dispatch(ServerRef, Message) ->
    gen_statem:cast(ServerRef, {dispatch, Message}).

-doc """
Same as calling is_connected(?SERVER).
""".
-spec is_connected() -> boolean().
is_connected() ->
    is_connected(?SERVER).

-doc """
Check if the bridge is connected to any hub.

### Example:
```
> ro2erl_bridge_server:is_connected(ServerRef).
true
```
""".
-spec is_connected(ServerRef :: pid() | atom()) -> boolean().
is_connected(ServerRef) ->
    gen_statem:call(ServerRef, is_connected).

-doc """
Same as calling get_metrics(?SERVER).
""".
-spec get_metrics() -> #{
    Name :: binary() => #{
        dispatched := #{bandwidth := non_neg_integer(), rate := float()},
        forwarded := #{bandwidth := non_neg_integer(), rate := float()}
    }
}.
get_metrics() ->
    get_metrics(?SERVER).

-doc """
Get current bandwidth and message rate estimates for all topics.
Returns both dispatched and forwarded metrics for each topic.

### Example:
```
> ro2erl_bridge_server:get_metrics(ServerRef).
#{
    <<"topic1">> => #{
        dispatched => #{bandwidth => 5000, rate => 50.0},
        forwarded => #{bandwidth => 4000, rate => 40.0}
    },
    <<"topic2">> => #{
        dispatched => #{bandwidth => 3000, rate => 30.0},
        forwarded => #{bandwidth => 2000, rate => 20.0}
    }
}
```
""".
-spec get_metrics(ServerRef :: pid() | atom()) -> #{
    Name :: binary() => #{
        dispatched := #{bandwidth := non_neg_integer(), rate := float()},
        forwarded := #{bandwidth := non_neg_integer(), rate := float()}
    }
}.
get_metrics(ServerRef) ->
    gen_statem:call(ServerRef, get_metrics).

-doc """
Same as calling set_topic_bandwidth(?SERVER, TopicName, Bandwidth).
""".
-spec set_topic_bandwidth(TopicName :: binary(), Bandwidth :: non_neg_integer() | infinity) -> ok.
set_topic_bandwidth(TopicName, Bandwidth) ->
    set_topic_bandwidth(?SERVER, TopicName, Bandwidth).

-doc """
Set the bandwidth limit for a topic.

The bandwidth limit is specified in bytes per second (byte/s). Setting it to infinity
removes the limit.

### Example:
```
> ro2erl_bridge_server:set_topic_bandwidth(ServerRef, <<"my_topic">>, 1000).
ok
> ro2erl_bridge_server:set_topic_bandwidth(ServerRef, <<"my_topic">>, infinity).
ok
```
""".
-spec set_topic_bandwidth(ServerRef :: pid() | atom(),
                          TopicName :: binary(),
                          Bandwidth :: non_neg_integer() | infinity) -> ok.
set_topic_bandwidth(ServerRef, TopicName, Bandwidth) ->
    gen_statem:call(ServerRef, {set_topic_bandwidth, TopicName, Bandwidth}).


%=== BEHAVIOUR GEN_STATEM CALLBACK FUNCTIONS ==================================

callback_mode() -> [state_functions].

init([HubMod, MsgProcessor]) ->
    % Read configuration
    Config = application:get_all_env(ro2erl_bridge),

    % Extract callback configuration (or use default)
    Callback = case proplists:get_value(dispatch_callback, Config) of
        {M, F} -> {M, F, []};
        {M, F, A} -> {M, F, A};
        undefined -> undefined
    end,

    % Generate a unique bridge ID
    BridgeId = generate_bridge_id(),

    % Initialize state
    {ok, disconnected, #data{
        hubs = #{},
        hub_mod = HubMod,
        local_callback = Callback,
        bridge_id = BridgeId,
        msg_processor = MsgProcessor
    }}.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.


%=== STATE FUNCTIONS =========================================================

disconnected(cast, {dispatch, _Message}, _Data) ->
    ?LOG_WARNING("Cannot forward message to hub: not connected"),
    keep_state_and_data;
disconnected({call, From}, is_connected, _Data) ->
    {keep_state_and_data, [{reply, From, false}]};
disconnected({call, From}, {detach, _HubPid}, _Data) ->
    % When disconnected, there are no hubs to detach from
    {keep_state_and_data, [{reply, From, {error, not_attached}}]};
disconnected(EventType, EventContent, Data) ->
    handle_common(EventType, EventContent, ?FUNCTION_NAME, Data).

connected({call, From}, is_connected, _Data) ->
    {keep_state_and_data, [{reply, From, true}]};
connected({call, From}, {detach, HubPid}, Data) ->
    case detach_from_hub(HubPid, Data) of
        {error, not_attached} ->
            {keep_state_and_data, [{reply, From, {error, not_attached}}]};
        {ok, NewData} ->
            % If no more hubs, transition to disconnected state
            case maps:size(NewData#data.hubs) of
                0 -> {next_state, disconnected, NewData, [{reply, From, ok}]};
                _ -> {keep_state, NewData, [{reply, From, ok}]}
            end
    end;
connected(cast, {dispatch, Message},
          Data = #data{topics = Topics, msg_processor = MsgProcessor}) ->
    % Process message to get topic info
    {topic, TopicName, Filterable, MsgSize} = MsgProcessor(Message),

    % Get or create topic record
    Topic = case maps:find(TopicName, Topics) of
        error ->
            #topic{filterable = Filterable};
        {ok, ExistingTopic} ->
            ExistingTopic#topic{filterable = Filterable}
    end,

    % Update dispatch metrics and check capacity
    {Capacity, UpdatedTopic} = update_dispatch_metrics(Topic, MsgSize),

    % Update topics map
    NewTopics = Topics#{TopicName => UpdatedTopic},
    NewData = Data#data{topics = NewTopics},

    % Check if we can forward the message
    % Always forward if not filterable, otherwise check capacity
    ForwardMessage = case {Filterable, Capacity} of
        {false, _} -> true;
        {true, infinity} -> true;
        {true, Remaining} when Remaining >= MsgSize -> true;
        _ -> false
    end,
    case ForwardMessage of
        true ->
            % Update forward metrics and forward message
            FinalTopic = update_forward_metrics(UpdatedTopic, MsgSize),
            FinalTopics = NewTopics#{TopicName => FinalTopic},
            FinalData = NewData#data{topics = FinalTopics},
            forward_to_all_hubs(Message, FinalData),
            {keep_state, FinalData};
        false ->
            ?LOG_DEBUG("Message dropped due to rate limiting: topic=~p, size=~p, remaining=~p",
                      [TopicName, MsgSize, Capacity]),
            {keep_state, NewData}
    end;
connected(cast, {hub_dispatch, Timestamp, Message}, Data) ->
    dispatch_locally(Timestamp, Message, Data),
    keep_state_and_data;
connected(EventType, EventContent, Data) ->
    handle_common(EventType, EventContent, ?FUNCTION_NAME, Data).


%=== COMMON EVENT HANDLING ====================================================

-doc """
Handle events common to all states

Processes events that are handled the same way regardless of current state.
""".
handle_common({call, From}, {attach, HubPid}, StateName, Data) ->
    case attach_to_hub(HubPid, Data) of
        {error, already_attached} ->
            {keep_state_and_data, [{reply, From, {error, already_attached}}]};
        {ok, NewData} ->
            % Transition to connected state if we're currently disconnected
            case {StateName, maps:size(Data#data.hubs)} of
                {disconnected, 0} -> {next_state, connected, NewData, [{reply, From, ok}]};
                _ -> {keep_state, NewData, [{reply, From, ok}]}
            end
    end;
handle_common({call, From}, get_metrics, _StateName, Data = #data{topics = Topics}) ->
    % Get metrics for each topic and build result map
    {Result, NewTopics} = maps:fold(fun(Name, Topic, {AccMetrics, AccTopics}) ->
        {Metrics, NewTopic} = get_topic_metrics(Topic),
        {AccMetrics#{Name => Metrics}, AccTopics#{Name => NewTopic}}
    end, {#{}, #{}}, Topics),
    {keep_state, Data#data{topics = NewTopics}, [{reply, From, Result}]};
handle_common({call, From}, {set_topic_bandwidth, TopicName, Bandwidth}, _StateName,
              Data = #data{topics = Topics}) ->
    % Get or create topic record
    Topic = maps:get(TopicName, Topics, #topic{}),

    % Update topic with new bandwidth limit
    UpdatedTopic = Topic#topic{limit = Bandwidth},
    NewTopics = Topics#{TopicName => UpdatedTopic},
    NewData = Data#data{topics = NewTopics},

    ?LOG_INFO("Set bandwidth limit for topic ~p to ~p", [TopicName, Bandwidth]),
    {keep_state, NewData, [{reply, From, ok}]};
handle_common(info, {'DOWN', MonRef, process, Pid, Reason}, StateName,
              Data = #data{hubs = Hubs}) ->
    % Check if this is one of our hubs
    case find_hub_by_monitor(MonRef, Hubs) of
        {ok, Pid} ->
            % Remove the hub from our map
            NewHubs = maps:remove(Pid, Hubs),
            NewData = Data#data{hubs = NewHubs},

            ?LOG_NOTICE("Detached from hub ~p: ~p", [Pid, Reason]),

            % Transition to disconnected state if there is no more hubs
            case {StateName, maps:size(NewHubs)} of
                {connected, 0} -> {next_state, disconnected, NewData};
                _ -> {keep_state, NewData}
            end;
        _ ->
            % Not our hub, ignore
            keep_state_and_data
    end;
handle_common(cast, Message, StateName, _Data) ->
    ?LOG_ERROR("Unexpected cast event in state ~p: ~p", [StateName, Message]),
    {stop, {error, {unexpected_cast, Message}}};
handle_common({call, From}, Message, StateName, _Data) ->
    ?LOG_ERROR("Unexpected call event from ~p in state ~p: ~p", [From, StateName, Message]),
    {stop, {error, {unexpected_call, Message}}, [{reply, From, {error, not_supported}}]};
handle_common(info, Message, StateName, _Data) ->
    ?LOG_WARNING("Unexpected info message in state ~p: ~p", [StateName, Message]),
    keep_state_and_data.


%=== INTERNAL FUNCTIONS ========================================================

-doc """
Find a hub by its monitor reference.
""".
-spec find_hub_by_monitor(MonRef :: reference(),
                          Hubs :: #{pid() => #hub{}}) ->
    {ok, pid()} | {error, not_found}.
find_hub_by_monitor(MonRef, Hubs) ->
    % Find hub that matches the monitor reference
    Result = maps:fold(fun(Pid, #hub{mon_ref = Ref}, Acc) ->
        case Ref =:= MonRef of
            true -> {ok, Pid};
            false -> Acc
        end
    end, {error, not_found}, Hubs),
    Result.

-doc """
Generate a unique bridge ID by combining node name with timestamp and random bytes.
""".
generate_bridge_id() ->
    % Combine node name with random bytes and encode in base64
    NodeBin = atom_to_binary(node(), utf8),
    Random = crypto:strong_rand_bytes(4),
    <<NodeBin/binary, "/",(base64:encode(Random))/binary>>.

-doc """
Attach this bridge to a hub.

Sets up monitoring, updates the hub map, and communicates with the hub.

### Returns:
- {ok, NewData} - Attachment successful, returns updated state
- {error, already_attached} - Hub is already attached
""".
-spec attach_to_hub(HubPid :: pid(), Data :: #data{}) ->
    {ok, #data{}} | {error, already_attached}.
attach_to_hub(HubPid, Data = #data{hubs = Hubs, bridge_id = BridgeId, hub_mod = HubMod}) ->
    case maps:is_key(HubPid, Hubs) of
        true ->
            {error, already_attached};
        false ->
            % Monitor hub process
            HubMon = monitor(process, HubPid),

            % Add hub to map
            NewHubs = maps:put(HubPid, #hub{mon_ref = HubMon}, Hubs),
            NewData = Data#data{hubs = NewHubs},

            % Use hub module's attach function to register with the hub
            HubMod:attach(HubPid, BridgeId, self()),

            ?LOG_NOTICE("Attached to hub ~p", [HubPid]),
            {ok, NewData}
    end.

-doc """
Detach this bridge from a hub.

Cleans up monitoring, updates the hub map, and communicates with the hub.

### Returns:
- {ok, NewData} - Detachment successful, returns updated state
- {error, not_attached} - Hub is not attached
""".
-spec detach_from_hub(HubPid :: pid(), Data :: #data{}) ->
    {ok, #data{}} | {error, not_attached}.
detach_from_hub(HubPid, Data = #data{hubs = Hubs, hub_mod = HubMod}) ->
    case maps:take(HubPid, Hubs) of
        error ->
            {error, not_attached};
        {#hub{mon_ref = MonRef}, NewHubs} ->
            % Demonitor hub process
            demonitor(MonRef),

            % Detach from hub
            HubMod:detach(HubPid, self()),

            % Update hub map
            NewData = Data#data{hubs = NewHubs},
            ?LOG_NOTICE("Detached from hub ~p", [HubPid]),
            {ok, NewData}
    end.

-doc """
Forward message to all connected hubs.
""".
forward_to_all_hubs(Message, Data = #data{hubs = Hubs}) ->
    % Forward message to each hub
    maps:foreach(fun(HubPid, _) ->
        forward_to_hub(HubPid, Message, Data)
    end, Hubs).

-doc """
Forward message to hub with metadata.
""".
forward_to_hub(HubPid, Message, #data{hub_mod = HubMod}) ->
    % Get current timestamp
    Timestamp = erlang:system_time(millisecond),

    % Send to hub using the configured hub module
    HubMod:dispatch(HubPid, self(), Timestamp, Message),
    ?LOG_DEBUG("Forwarded message to hub ~p: ~p", [HubPid, Message]).

-doc """
Dispatch received message locally using configured callback.
""".
dispatch_locally(Timestamp, Message, #data{local_callback = Callback}) ->
    ?LOG_DEBUG("Received message from hub (timestamp: ~p): ~p", [Timestamp, Message]),
    case Callback of
        undefined ->
            % No callback configured
            ?LOG_WARNING("No dispatch callback configured, message dropped"),
            ok;
        {M, F, A} ->
            % Call configured callback with message and additional args
            try
                erlang:apply(M, F, [Message | A])
            catch
                E:R:Stack ->
                    ?LOG_ERROR("Error dispatching message locally: ~p:~p~n~p",
                              [E, R, Stack])
            end
    end.

-doc """
Calculate the current time and last update timestamps for a topic, handling time discrepancies.
Returns {Now, DLast, FLast, NewTopic} where:
- Now is the most recent timestamp we've seen
- DLast is the last dispatch update time
- FLast is the last forward update time
- NewTopic is the updated topic record (reset if time discrepancy is detected)
""".
-spec get_topic_timestamps(#topic{}) ->
    {non_neg_integer(), non_neg_integer(), non_neg_integer(), #topic{}}.
get_topic_timestamps(Topic = #topic{
    dispatch_last_update = DLastUpdate0,
    forward_last_update = FLastUpdate0
}) ->
    Current = erlang:system_time(milli_seconds),

    % Determine the most recent timestamp we've seen
    {MostRecent, DLastUpdate, FLastUpdate} =
        case {DLastUpdate0, FLastUpdate0} of
            {undefined, undefined} ->
                {Current, Current, Current};
            {undefined, F} ->
                M = max(Current, F),
                {M, M, F};
            {D, undefined} ->
                M = max(Current, D),
                {M, D, M};
            {D, F} ->
                M = max(Current, max(D, F)),
                {M, D, F}
        end,

    % If current time is less than most recent, we had an NTP adjustment
    case Current < MostRecent of
        true ->
            ?LOG_WARNING("Time went backwards: dispatch_last=~p, forward_last=~p, now=~p",
                         [DLastUpdate, FLastUpdate, Current]),
            % Reset the topic completely to start fresh
            ResetTopic = Topic#topic{
                dispatch_last_update = Current,
                forward_last_update = Current,
                bytes_dispatched = 0,
                msgs_dispatched = 0.0,
                bytes_forwarded = 0,
                msgs_forwarded = 0.0
            },
            {Current, Current, Current, ResetTopic};
        false ->
            {MostRecent, DLastUpdate, FLastUpdate, Topic}
    end.

-doc """
Update topic metrics after message dispatch using a rolling window algorithm.
This function should be called after a message is received from the local network.
The function returns the remaining capacity for the topic within the current time window.
For infinite limits, it returns infinity. For finite limits, it calculates how many bytes
can still be dispatched in the current window before hitting the limit.
""".
-spec update_dispatch_metrics(Topic :: #topic{}, MsgSize :: non_neg_integer()) ->
    {
        Remaining :: non_neg_integer() | infinity,
        NewTopic  :: #topic{}
    }.
update_dispatch_metrics(Topic, MsgSize) ->
    #topic{
        bytes_dispatched = Bytes,
        msgs_dispatched = Msgs,
        limit = Limit
    } = Topic,

    % Get current time and handle NTP time adjustments
    {Now, Last, _, UpdatedTopic} = get_topic_timestamps(Topic),

    % Update metrics using the metrics module
    {NewBytes, NewMsgs, _Bandwidth, _MsgRate, Capacity}
        = ro2erl_bridge_metrics:update(Last, Now, Bytes, Msgs, Limit, MsgSize),

    % Update topic record with new values
    NewTopic = UpdatedTopic#topic{
        dispatch_last_update = Now,
        bytes_dispatched = NewBytes,
        msgs_dispatched = NewMsgs
    },
    {Capacity, NewTopic}.

-doc """
Update topic metrics after message forwarding using a rolling window algorithm.
This function should be called after a message is forwarded to the hub.
""".
-spec update_forward_metrics(Topic :: #topic{}, MsgSize :: non_neg_integer()) ->
    #topic{}.
update_forward_metrics(Topic, MsgSize) ->
    #topic{
        bytes_forwarded = Bytes,
        msgs_forwarded = Msgs
    } = Topic,

    % Get current time and handle NTP time adjustments
    {Now, _, Last, UpdatedTopic} = get_topic_timestamps(Topic),

    % Update metrics using the metrics module
    {NewBytes, NewMsgs, _Bandwidth, _MsgRate, _Capacity}
        = ro2erl_bridge_metrics:update(Last, Now, Bytes, Msgs, infinity, MsgSize),

    % Update topic record with new values
    UpdatedTopic#topic{
        forward_last_update = Now,
        bytes_forwarded = NewBytes,
        msgs_forwarded = NewMsgs
    }.

-doc """
Get current bandwidth and message rate estimates for a topic.
Calculates the current state of the token buckets by applying time-based decay,
and returns both dispatched and forwarded metrics.

The function does not modify the topic's metrics, it only calculates their current
state based on the time elapsed since the last update.
""".
-spec get_topic_metrics(Topic :: #topic{}) ->
    {
        #{
            dispatched := #{bandwidth := non_neg_integer(), rate := float()},
            forwarded := #{bandwidth := non_neg_integer(), rate := float()}
        },
        #topic{}
    }.
get_topic_metrics(Topic) ->
    #topic{
        bytes_dispatched = DBytes,
        msgs_dispatched = DMsgs,
        bytes_forwarded = FBytes,
        msgs_forwarded = FMsgs,
        limit = Limit
    } = Topic,

    % Get current time and handle NTP time adjustments
    {Now, DLast, FLast, UpdatedTopic} = get_topic_timestamps(Topic),

    % Calculate current metrics for dispatched data
    {NewDBytes, NewDMsgs, DBandwidth, DRate, _}
        = ro2erl_bridge_metrics:update(DLast, Now, DBytes, DMsgs, Limit, undefined),

    % Calculate current metrics for forwarded data
    {NewFBytes, NewFMsgs, FBandwidth, FRate, _}
        = ro2erl_bridge_metrics:update(FLast, Now, FBytes, FMsgs, infinity, undefined),

    % Build metrics map
    Metrics = #{
        dispatched => #{bandwidth => DBandwidth, rate => DRate},
        forwarded => #{bandwidth => FBandwidth, rate => FRate}
    },

    % Update topic with decayed values and current timestamp
    FinalTopic = UpdatedTopic#topic{
        dispatch_last_update = Now,
        forward_last_update = Now,
        bytes_dispatched = NewDBytes,
        msgs_dispatched = NewDMsgs,
        bytes_forwarded = NewFBytes,
        msgs_forwarded = NewFMsgs
    },

    {Metrics, FinalTopic}.
