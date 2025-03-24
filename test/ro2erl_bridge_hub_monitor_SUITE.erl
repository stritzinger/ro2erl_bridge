-module(ro2erl_bridge_hub_monitor_SUITE).

-moduledoc """
Test suite for ro2erl_bridge_hub_monitor
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%=== EXPORTS ===================================================================

%% Test server callbacks
-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

%% Test cases
-export([attach_existing_hubs_test/1]).
-export([hub_discovery_test/1]).

%% Bridge server callbacks
-export([attach/2]).
-export([detach/2]).

%% Function called on slave nodes
-export([hub_start/0]).


%=== MACROS ===================================================================

-define(HUB_SCOPE, test_hub_scope).
-define(HUB_GROUP, test_hub_group).
-define(assertAttached(PID), fun() ->
    receive
        {attach, PID} -> ok
    after 1000 ->
        ct:fail({attach_timeout, PID, ?MODULE, ?LINE})
    end
end()).
-define(assertDetached(PID), fun() ->
    receive
        {detach, PID} -> ok
    after 1000 ->
        ct:fail({detach_timeout, PID, ?MODULE, ?LINE})
    end
end()).
-define(assertNoMessage(), fun() ->
    receive
        {attach, Pid} -> ct:fail({unexpected_attach, Pid, ?MODULE, ?LINE});
        {detach, Pid} -> ct:fail({unexpected_detach, Pid, ?MODULE, ?LINE})
    after 300 ->
        ok
    end
end()).

%=== TEST SERVER CALLBACKS ====================================================

all() -> [
    attach_existing_hubs_test,
    hub_discovery_test
].

init_per_suite(Config) ->
    % Start net_kernel if not already started
    case net_kernel:start([ct_master, shortnames]) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        Error -> ct:fail({failed_to_start_net_kernel, Error})
    end,
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    {ok, _} = pg:start_link(?HUB_SCOPE),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.


%=== TEST CASES ==============================================================

-doc """
Test that existing hubs in the process group are detected and attached.
""".
attach_existing_hubs_test(_Config) ->
    % Start a new node for the hubs
    Hub1 = start_hub_node(),
    Hub2 = start_hub_node(),
    Hub3 = start_hub_node(),
    % Start a process on the two hubs nodes that will act as the hub managers
    HubProc1 = start_hub_process(Hub1),
    HubProc2 = start_hub_process(Hub2),

    % Start the hub monitor
    {ok, HubMon} = ro2erl_bridge_hub_monitor:start_link(
        {?MODULE, self()},
        {?HUB_SCOPE, ?HUB_GROUP}
    ),
    ?assertAttached(HubProc1),
    ?assertAttached(HubProc2),

    % Cleanup
    gen_server:stop(HubMon),
    stop_hub_node(Hub1),
    stop_hub_node(Hub2),
    stop_hub_node(Hub3),

    ?assertNoMessage(),
    ok.

-doc """
Test that hubs are properly discovered as they join and leave.
""".
hub_discovery_test(_Config) ->
    % Start the hub monitor first
    {ok, HubMon} = ro2erl_bridge_hub_monitor:start_link(
        {?MODULE, self()},
        {?HUB_SCOPE, ?HUB_GROUP}
    ),
    ?assertNoMessage(),

    % Start first node - nothing should happen yet
    Hub1 = start_hub_node(),
    ?assertNoMessage(),

    % Start second node - still nothing should happen
    Hub2 = start_hub_node(),
    ?assertNoMessage(),

    % Start a hub process on first node - should get attach message
    HubProc1 = start_hub_process(Hub1),
    ?assertAttached(HubProc1),

    % Start a hub process on second node - should get another attach message
    HubProc2 = start_hub_process(Hub2),
    ?assertAttached(HubProc2),

    % Stop first hub process - should get detach message
    stop_hub_process(HubProc1),
    ?assertDetached(HubProc1),

    % Stop second node - should get detach message for its hub process
    stop_hub_node(Hub2),
    ?assertDetached(HubProc2),

    % Cleanup
    gen_server:stop(HubMon),
    stop_hub_node(Hub1),

    ?assertNoMessage(),
    ok.


%=== BRIDGE SERVER CALLBACKS =================================================

attach(TestPid, Pid) ->
    ct:pal("Attach called with pid ~p on node ~p", [Pid, node()]),
    TestPid ! {attach, Pid},
    ok.

detach(TestPid, Pid) ->
    ct:pal("Detach called with pid ~p on node ~p", [Pid, node()]),
    TestPid ! {detach, Pid},
    ok.


%=== INTERNAL FUNCTIONS =====================================================

start_hub_node() ->
    {ok, Peer, Node} = ?CT_PEER(),
    {Peer, Node}.

start_hub_process({_Peer, Node}) ->
    rpc:call(Node, ?MODULE, hub_start, []).

stop_hub_node({Peer, _Node}) ->
    peer:stop(Peer).

stop_hub_process(Pid) ->
    MonRef = erlang:monitor(process, Pid),
    Pid ! stop,
    receive
      {'DOWN', MonRef, process, Pid, _} -> ok
    after 1000 ->
        ct:fail(stop_timeout)
    end.

hub_start() ->
    spawn(fun() ->
        pg:start_link(?HUB_SCOPE),
        ok = pg:join(?HUB_SCOPE, ?HUB_GROUP, self()),
        receive stop -> ok end
    end).
