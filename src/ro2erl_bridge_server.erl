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
-export([start_link/1]).
-export([attach/1, attach/2]).
-export([detach/1, detach/2]).
-export([dispatch/1, dispatch/2]).

%% Behaviour gen_statem callback functions
-export([callback_mode/0]).
-export([init/1]).
-export([terminate/3]).
-export([code_change/4]).

%% State functions
-export([disconnected/3]).
-export([connected/3]).


%=== MACROS ====================================================================

-define(SERVER, ?MODULE).


%=== TYPES =====================================================================

-record(hub, {
    mon_ref :: reference()
    % Future fields for filtering rules will go here
}).

-record(data, {
    hubs = #{} :: #{pid() => #hub{}},  % Map of hub pids to hub records
    hub_mod :: module(),               % Module to use for hub communication
    local_callback :: undefined | {module(), atom(), list()},
    bridge_id :: undefined | binary()
}).


%=== API FUNCTIONS =============================================================

start_link(HubMod) ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [HubMod], []).

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


%=== BEHAVIOUR GEN_STATEM CALLBACK FUNCTIONS ==================================

callback_mode() -> [state_functions].

init([HubMod]) ->
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
        bridge_id = BridgeId
    }}.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.


%=== STATE FUNCTIONS =========================================================

disconnected(cast, {dispatch, _Message}, _Data) ->
    ?LOG_WARNING("Cannot forward message to hub: not connected"),
    keep_state_and_data;
disconnected({call, From}, {detach, _HubPid}, _Data) ->
    % When disconnected, there are no hubs to detach from
    {keep_state_and_data, [{reply, From, {error, not_attached}}]};
disconnected(EventType, EventContent, Data) ->
    handle_common(EventType, EventContent, ?FUNCTION_NAME, Data).

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
connected(cast, {dispatch, Message}, Data) ->
    % Forward message to all hubs
    forward_to_all_hubs(Message, Data),
    keep_state_and_data;
connected(cast, {hub_api_dispatch, Message}, Data) ->
    dispatch_locally(Message, Data),
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
handle_common(info, {'DOWN', MonRef, process, _Pid, _Reason}, StateName,
              Data = #data{hubs = Hubs, hub_mod = HubMod}) ->
    % Check if this is one of our hubs
    case find_hub_by_monitor(MonRef, Hubs) of
        {ok, HubPid} ->
            % Remove the hub from our map
            NewHubs = maps:remove(HubPid, Hubs),
            NewData = Data#data{hubs = NewHubs},

            % Detach from hub
            HubMod:detach(HubPid, self()),

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
    Random = crypto:strong_rand_bytes(8),
    BridgeId = base64:encode(<<NodeBin/binary, Random/binary>>),
    BridgeId.

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
forward_to_hub(HubPid, Message, #data{bridge_id = BridgeId, hub_mod = HubMod}) ->
    % Wrap message with metadata
    WrappedMessage = #{
        bridge_id => BridgeId,
        timestamp => erlang:system_time(millisecond),
        payload => Message
    },

    % Send to hub using the configured hub module
    HubMod:dispatch(HubPid, WrappedMessage).

-doc """
Dispatch received message locally using configured callback.
""".
dispatch_locally(Message, #data{local_callback = Callback}) ->
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
