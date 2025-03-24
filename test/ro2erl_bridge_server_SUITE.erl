-module(ro2erl_bridge_server_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").


%=== EXPORTS ===================================================================

%% Test exports
-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

% Test functions
-export([
    % Connection tests
    attach_test/1,
    detach_test/1,
    hub_crash_test/1,
    multiple_hubs_test/1
]).

%% Test Hub API - Used by the bridge
-export([
    attach/3,
    detach/2,
    dispatch/2
]).


%=== MACROS ===================================================================

%% Assertion macros
-define(assertAttached(HUB_PID, BRIDGE_ID, BRIDGE_PID), fun() ->
    receive
        {attach, HUB_PID, BRIDGE_ID, BRIDGE_PID} -> ok
    after 1000 ->
        ct:fail({attach_timeout, ?MODULE, ?LINE})
    end
end()).

-define(assertDetached(HUB_PID, BRIDGE_PID), fun() ->
    receive
        {detach, HUB_PID, BRIDGE_PID} -> ok
    after 1000 ->
        ct:fail({detach_timeout, ?MODULE, ?LINE})
    end
end()).

-define(assertDispatched(HUB_PID, MESSAGE), fun() ->
    receive
        {dispatch, HUB_PID, Msg} when Msg == MESSAGE -> ok;
        {dispatch, HUB_PID, #{payload := MESSAGE}} -> ok
    after 1000 ->
        ct:fail({dispatch_timeout, MESSAGE, ?MODULE, ?LINE})
    end
end()).

-define(assertNoMessage(), fun() ->
    receive
        Any -> ct:fail({unexpected_message, Any, ?MODULE, ?LINE})
    after 300 ->
        ok
    end
end()).


%=== CT CALLBACKS =============================================================

all() -> [
    attach_test,
    detach_test,
    hub_crash_test,
    multiple_hubs_test
].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(dispatch_callback_invocation_test, Config) ->
    % For callback tests, set dispatch callback in environment
    application:set_env(ro2erl_bridge, dispatch_callback, {?MODULE, handle_message}),
    init_base_testcase(Config);
init_per_testcase(_TestCase, Config) ->
    init_base_testcase(Config).

init_base_testcase(Config) ->
    % Start the bridge server with this module as the hub module
    {ok, BridgePid} = ro2erl_bridge_server:start_link(?MODULE),

    % Drain any previous messages from mailbox
    flush_mailbox(),

    [{bridge_pid, BridgePid} | Config].

end_per_testcase(_TestCase, Config) ->
    % Stop the bridge
    BridgePid = proplists:get_value(bridge_pid, Config),
    gen_statem:stop(BridgePid),

    % Clear any test app env
    application:unset_env(ro2erl_bridge, dispatch_callback),

    Config.


%=== TEST CASES ==============================================================

%% Connection Tests
attach_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach to the hub (which is the test process)
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),

    ?assertAttached(TestPid, _, BridgePid),

    ?assertEqual({error, already_attached}, ro2erl_bridge_server:attach(BridgePid, TestPid)),

    % Verify messages are dispatched after attaching
    TestMessage = {test_message, <<"After attach">>},
    ro2erl_bridge_server:dispatch(BridgePid, TestMessage),

    % Verify we receive the dispatched message
    ?assertDispatched(TestPid, TestMessage),

    ?assertNoMessage(),
    ok.

detach_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach to the hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),

    ?assertAttached(TestPid, _, BridgePid),

    % Detach
    ok = ro2erl_bridge_server:detach(BridgePid, TestPid),

    % Assert we got a detach message
    ?assertDetached(TestPid, BridgePid),

    % Verify detaching again returns error
    ?assertEqual({error, not_attached}, ro2erl_bridge_server:detach(BridgePid, TestPid)),

    % Verify messages are no longer forwarded to hub
    TestMessage = {test, <<"After detach">>},
    ro2erl_bridge_server:dispatch(BridgePid, TestMessage),

    % Should not receive any dispatch message
    ?assertNoMessage(),
    ok.

hub_crash_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Create a hub process
    HubProc = spawn(fun() -> hub_proc(TestPid) end),

    % Attach the bridge to the hub
    ok = ro2erl_bridge_server:attach(BridgePid, HubProc),

    ?assertAttached(HubProc, _, BridgePid),

    % Send a message - should be forwarded to the hub
    TestMessage = {test_message, <<"To Hub">>},
    ro2erl_bridge_server:dispatch(TestMessage),

    ?assertDispatched(HubProc, TestMessage),

    % Kill the hub
    exit(HubProc, kill),

    % Wait for the monitor to trigger
    timer:sleep(100),

    ?assertDetached(HubProc, BridgePid),

    % Send another message - should not be forwarded
    TestMessage2 = {test_message, <<"After hub crash">>},
    ro2erl_bridge_server:dispatch(TestMessage2),

    % We should not receive any message
    ?assertNoMessage(),
    ok.

multiple_hubs_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Create the first hub process
    Hub1 = spawn(fun() -> hub_proc(TestPid) end),

    % Attach to the first hub
    ok = ro2erl_bridge_server:attach(BridgePid, Hub1),

    % Verify attachment to first hub
    ?assertAttached(Hub1, _, BridgePid),

    % Send a message - should be forwarded to the first hub
    TestMessage1 = {test_message, <<"To Hub1">>},
    ro2erl_bridge_server:dispatch(BridgePid, TestMessage1),

    % Verify hub1 received the message
    ?assertDispatched(Hub1, TestMessage1),

    % Create a second hub process
    Hub2 = spawn(fun() -> hub_proc(TestPid) end),

    % Attach to the second hub
    ok = ro2erl_bridge_server:attach(BridgePid, Hub2),

    % Verify attachment to second hub
    ?assertAttached(Hub2, _, BridgePid),

    % Send a message - should be forwarded to both hubs
    TestMessage2 = {test_message, <<"To Both Hubs">>},
    ro2erl_bridge_server:dispatch(BridgePid, TestMessage2),

    % Verify both hubs received the message
    ?assertDispatched(Hub1, TestMessage2),
    ?assertDispatched(Hub2, TestMessage2),

    % Create a third hub process
    Hub3 = spawn(fun() -> hub_proc(TestPid) end),

    % Attach to the third hub
    ok = ro2erl_bridge_server:attach(BridgePid, Hub3),

    % Verify attachment to third hub
    ?assertAttached(Hub3, _, BridgePid),

    % Send a message - should be forwarded to all three hubs
    TestMessage3 = {test_message, <<"To All Three Hubs">>},
    ro2erl_bridge_server:dispatch(BridgePid, TestMessage3),

    % Verify all three hubs received the message
    ?assertDispatched(Hub1, TestMessage3),
    ?assertDispatched(Hub2, TestMessage3),
    ?assertDispatched(Hub3, TestMessage3),

    % Kill the first hub
    exit(Hub1, kill),

    % Wait for the monitor to trigger
    timer:sleep(100),

    % Verify hub1 was detached
    ?assertDetached(Hub1, BridgePid),

    % Send a message - should be forwarded to the remaining hubs
    TestMessage4 = {test_message, <<"After Hub1 Crash">>},
    ro2erl_bridge_server:dispatch(BridgePid, TestMessage4),

    % Verify only hub2 and hub3 received the message
    ?assertDispatched(Hub2, TestMessage4),
    ?assertDispatched(Hub3, TestMessage4),

    % Explicitly detach from hub2
    ok = ro2erl_bridge_server:detach(BridgePid, Hub2),

    % Verify hub2 was detached
    ?assertDetached(Hub2, BridgePid),

    % Send a message - should only be forwarded to hub3
    TestMessage5 = {test_message, <<"Only To Hub3">>},
    ro2erl_bridge_server:dispatch(BridgePid, TestMessage5),

    % Verify only hub3 received the message
    ?assertDispatched(Hub3, TestMessage5),

    ?assertNoMessage(),


    % Clean up - stopping hub3
    Hub3 ! stop,

    % Verify hub3 was detached
    ?assertDetached(Hub3, BridgePid),

    % We should not receive any more message
    ?assertNoMessage(),

    ok.

%=== HUB API IMPLEMENTATION ===================================================

%% Test Hub API Implementation - These are called by the bridge

attach(HubPid, BridgeId, BridgePid) ->
    current_test ! {attach, HubPid, BridgeId, BridgePid},
    ok.

detach(HubPid, BridgePid) ->
    current_test ! {detach, HubPid, BridgePid},
    ok.

dispatch(HubPid, Message) ->
    current_test ! {dispatch, HubPid, Message},
    ok.


%=== INTERNAL HELPER FUNCTIONS =================================================

flush_mailbox() ->
    receive
        _Any -> flush_mailbox()
    after 0 ->
        ok
    end.

hub_proc(TestPid) ->
    receive
        {attach, _HubPid, _BridgeId, _BridgePid} = Msg ->
            TestPid ! Msg,
            hub_proc(TestPid);
        {detach, _HubPid, _BridgePid} = Msg ->
            TestPid ! Msg,
            hub_proc(TestPid);
        {dispatch, _HubPid, _Message} = Msg ->
            TestPid ! Msg,
            hub_proc(TestPid);
        stop ->
            ok
    end.
