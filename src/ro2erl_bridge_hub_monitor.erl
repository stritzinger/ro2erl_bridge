-module(ro2erl_bridge_hub_monitor).

-moduledoc """
Monitor for Hub nodes and Hub processes

This module is responsible for:
1. Monitoring hub processes in the process group
2. Notifying the bridge server when hubs join or leave
""".

-behaviour(gen_server).

%=== EXPORTS ===================================================================

%% API functions
-export([start_link/2]).

%% Behaviour gen_server callback functions
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).


%=== MACROS ====================================================================

-define(SERVER, ?MODULE).


%=== TYPES =====================================================================

-record(state, {
    hubs = [] :: [pid()],  % List of hub pids
    server_spec :: {module(), pid() | atom()}, % Tuple of server module and reference
    hub_group :: {atom(), atom()},         % Tuple of pg scope and group name
    mon_ref :: reference()                 % Monitor reference for the process group
}).


%=== API FUNCTIONS =============================================================

-doc """
Starts the hub monitor process linked to the current process.

### Parameters:
- ServerSpec: {ServerMod, ServerRef} - Module and process reference for bridge server
- HubGroup: {Scope, Group} - Process group scope and name for hubs
""".
start_link(ServerSpec = {_ServerMod, _ServerRef}, HubGroup = {_Scope, _Group}) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [ServerSpec, HubGroup], []).


%=== BEHAVIOUR gen_server CALLBACK FUNCTIONS ===================================

init([ServerSpec, HubGroup = {Scope, Group}]) ->
    % Monitor the hub process group
    {MonRef, Members} = pg:monitor(Scope, Group),
    % Initialize state and add existing members
    State = #state{
        server_spec = ServerSpec,
        hub_group = HubGroup,
        mon_ref = MonRef
    },
    {ok, hub_add(State, Members)}.

handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({MonRef, join, Group, Pids},
            State = #state{mon_ref = MonRef, hub_group = {_Scope, Group}}) ->
    {noreply, hub_add(State, Pids)};
handle_info({MonRef, leave, Group, Pids},
            State = #state{mon_ref = MonRef, hub_group = {_Scope, Group}}) ->
    {noreply, hub_del(State, Pids)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%=== INTERNAL FUNCTIONS ========================================================

-doc """
Add hubs to the state and notify bridge server.

For each process ID in the list, adds it to the hubs list if not already present
and notifies the bridge server via the attach function.
""".
-spec hub_add(State :: #state{}, Pids :: [pid()]) -> #state{}.
hub_add(State = #state{server_spec = {ServerMod, ServerRef}}, Pids) ->
    % Add each pid to the set and notify bridge server if not already present
    lists:foldl(fun(Pid, AccState = #state{hubs = Hubs}) ->
        case lists:member(Pid, Hubs) of
            true ->
                AccState;
            false ->
                % Inform bridge server
                ServerMod:attach(ServerRef, Pid),
                % Update state
                AccState#state{hubs = [Pid | Hubs]}
        end
    end, State, Pids).

-doc """
Remove hubs from the state and notify bridge server.

For each process ID in the list, removes it from the hubs list if present
and notifies the bridge server via the detach function.
""".
-spec hub_del(State :: #state{}, Pids :: [pid()]) -> #state{}.
hub_del(State = #state{server_spec = {ServerMod, ServerRef}}, Pids) ->
    % Remove each pid from the set and notify bridge server if it was present
    lists:foldl(fun(Pid, AccState = #state{hubs = Hubs}) ->
        case lists:member(Pid, Hubs) of
            true ->
                % Notify bridge server
                ServerMod:detach(ServerRef, Pid),
                % Update state
                AccState#state{hubs = lists:delete(Pid, Hubs)};
            false ->
                AccState
        end
    end, State, Pids).
