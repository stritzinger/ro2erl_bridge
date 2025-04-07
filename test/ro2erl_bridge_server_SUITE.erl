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
    multiple_hubs_test/1,
    % Metrics tests
    initial_metrics_test/1,
    metrics_update_test/1,
    metrics_decay_test/1,
    metrics_window_test/1,
    % Bandwidth limit tests
    bandwidth_limit_set_test/1,
    bandwidth_limit_remove_test/1,
    % Non-filterable tests
    non_filterable_always_forward_test/1,
    % Multiple topics tests
    multiple_topics_metrics_test/1,
    % Future test cases
    hub_set_bandwidth_test/1,
    dispatch_callback_test/1,
    topic_update_test/1,
    % Custom payload test
    custom_payload_test/1
]).

%% Test Hub API - Used by the bridge
-export([
    attach/3,
    detach/2,
    dispatch/4,
    update_topics/3
]).

%% Test callback functions
-export([
    test_message_processor/1,
    test_dispatch_callback/1
]).


%=== MACROS ===================================================================

-define(FMT(F, A), lists:flatten(io_lib:format(F, A))).

%% Assertion macros
-define(assertAttached(HUB_PID, BRIDGE_ID, BRIDGE_PID), fun() ->
    receive
        {bridge_attach, HUB_PID, BRIDGE_ID, BRIDGE_PID} -> ok
    after 1000 ->
        ct:fail({attach_timeout, ?FUNCTION_NAME, ?LINE})
    end
end()).

-define(assertDetached(HUB_PID, BRIDGE_PID), fun() ->
    receive
        {bridge_detach, HUB_PID, BRIDGE_PID} -> ok
    after 1000 ->
        ct:fail({detach_timeout, ?FUNCTION_NAME, ?LINE})
    end
end()).

-define(assertDispatched(HUB_PID, MESSAGE), fun() ->
    receive
        {bridge_dispatch, HUB_PID, SenderPid, Timestamp, Msg}
          when Msg == MESSAGE, is_pid(SenderPid), is_integer(Timestamp) -> ok
    after 1000 ->
        ct:fail({dispatch_timeout, MESSAGE, ?FUNCTION_NAME, ?LINE})
    end
end()).

-define(assertTopicUpdated(HUB_PID, TOPICS), fun() ->
    receive
        {bridge_update_topics, HUB_PID, _, TOPICS = M_Topics} -> M_Topics
    after 1500 ->
        ct:fail({topic_update_timeout, ?FUNCTION_NAME, ?LINE})
    end
end()).

-define(assertDispatchedLocally(MESSAGE), fun() ->
    receive
        {local_dispatch, Msg} when Msg == MESSAGE -> ok
    after 1000 ->
        ct:fail({local_dispatch_timeout, MESSAGE, ?FUNCTION_NAME, ?LINE})
    end
end()).

-define(assertNoMessage(), fun() ->
    receive
        Any -> ct:fail({unexpected_message, Any, ?FUNCTION_NAME, ?LINE})
    after 300 ->
        ok
    end
end()).

-define(assertConnected(BRIDGE_PID), fun() ->
    ?assertEqual(true, ro2erl_bridge_server:is_connected(BRIDGE_PID))
end()).

-define(assertDisconnected(BRIDGE_PID), fun() ->
    ?assertEqual(false, ro2erl_bridge_server:is_connected(BRIDGE_PID))
end()).

-define(assertNoDispatchMessage(), fun() ->
    fun M_ReceiveLoop() ->
        receive
            {bridge_update_topics, _, _, _} ->
                % Ignore topic updates, recursively check for other messages
                M_ReceiveLoop();
            Any ->
                ct:fail({unexpected_message, Any, ?MODULE, ?LINE})
        after 300 ->
            ok
        end
    end()
end()).


%=== CT CALLBACKS ==============================================================

all() -> [
    attach_test,
    detach_test,
    hub_crash_test,
    multiple_hubs_test,
    initial_metrics_test,
    metrics_update_test,
    metrics_decay_test,
    metrics_window_test,
    bandwidth_limit_set_test,
    bandwidth_limit_remove_test,
    non_filterable_always_forward_test,
    multiple_topics_metrics_test,
    % Future test cases
    hub_set_bandwidth_test,
    dispatch_callback_test,
    topic_update_test,
    % Custom payload test
    custom_payload_test
].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(dispatch_callback_test, Config) ->
    init_base_testcase(Config, fun test_dispatch_callback/1);
init_per_testcase(_TestCase, Config) ->
    init_base_testcase(Config, undefined).

init_base_testcase(Config, DispatchCallback) ->
    % Start the bridge server with this module as the hub module
    {ok, BridgePid} = ro2erl_bridge_server:start_link(
        ?MODULE, fun test_message_processor/1, DispatchCallback),

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

    % Initially disconnected
    ?assertDisconnected(BridgePid),

    % Attach to the hub (which is the test process)
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),

    % Verify we're connected
    ?assertConnected(BridgePid),
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

    % Initially disconnected
    ?assertDisconnected(BridgePid),

    % Attach to the hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),

    % Verify we're connected
    ?assertConnected(BridgePid),
    ?assertAttached(TestPid, _, BridgePid),

    % Detach
    ok = ro2erl_bridge_server:detach(BridgePid, TestPid),

    % Verify we're disconnected
    ?assertDisconnected(BridgePid),
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

    % Initially disconnected
    ?assertDisconnected(BridgePid),

    % Create a hub process
    HubProc = spawn(fun() -> hub_proc(TestPid) end),

    % Attach the bridge to the hub
    ok = ro2erl_bridge_server:attach(BridgePid, HubProc),

    % Verify we're connected
    ?assertConnected(BridgePid),
    ?assertAttached(HubProc, _, BridgePid),

    % Send a message - should be forwarded to the hub
    TestMessage = {test_message, <<"To Hub">>},
    ro2erl_bridge_server:dispatch(TestMessage),

    ?assertDispatched(HubProc, TestMessage),

    % Kill the hub
    exit(HubProc, kill),

    % Wait for the monitor to trigger
    timer:sleep(100),

    % Verify we're disconnected
    ?assertDisconnected(BridgePid),

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

    % Initially disconnected
    ?assertDisconnected(BridgePid),

    % Create the first hub process
    Hub1 = spawn(fun() -> hub_proc(TestPid) end),

    % Attach to the first hub
    ok = ro2erl_bridge_server:attach(BridgePid, Hub1),

    % Verify we're connected
    ?assertConnected(BridgePid),
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

    % Verify we're still connected
    ?assertConnected(BridgePid),
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

    % Verify we're still connected
    ?assertConnected(BridgePid),
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

    % Verify we're still connected (we have other hubs)
    ?assertConnected(BridgePid),
    % Verify hub1 was detached
    % ?assertDetached(Hub1, BridgePid),  % Removed: bridge only receives DOWN message

    % Send a message - should be forwarded to the remaining hubs
    TestMessage4 = {test_message, <<"After Hub1 Crash">>},
    ro2erl_bridge_server:dispatch(BridgePid, TestMessage4),

    % Verify only hub2 and hub3 received the message
    ?assertDispatched(Hub2, TestMessage4),
    ?assertDispatched(Hub3, TestMessage4),

    % Explicitly detach from hub2
    ok = ro2erl_bridge_server:detach(BridgePid, Hub2),

    % Verify we're still connected (we have hub3)
    ?assertConnected(BridgePid),
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

    % Wait for the monitor to trigger
    timer:sleep(100),

    % Verify we're disconnected (no more hubs)
    ?assertDisconnected(BridgePid),

    % We should not receive any more message
    ?assertNoMessage(),

    ok.

%% Metrics Tests
initial_metrics_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach the bridge to the test process as a hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),
    ?assertAttached(TestPid, _, BridgePid),

    % Create a test topic by explicitly setting a bandwidth limit
    TopicName = <<"test_topic">>,
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, TopicName, 1000),

    % Get metrics for our topic
    Metrics = ro2erl_bridge_server:get_metrics(BridgePid),

    % Verify the topic exists in metrics
    ?assert(maps:is_key(TopicName, Metrics), "Topic should exist in metrics"),

    % Get topic metrics
    TopicMetrics = maps:get(TopicName, Metrics),

    % Verify all metrics are zero
    ?assertEqual(#{bandwidth => 0, rate => 0.0}, maps:get(dispatched, TopicMetrics)),
    ?assertEqual(#{bandwidth => 0, rate => 0.0}, maps:get(forwarded, TopicMetrics)),

    % Verify no messages were forwarded to hub
    ?assertNoMessage(),

    ok.

metrics_update_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach the bridge to the test process as a hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),
    ?assertAttached(TestPid, _, BridgePid),

    % Define the test topic and message
    TopicName = <<"test_topic">>,
    MsgSize = 100,
    TestMessage = {test_message, TopicName, true, MsgSize},

    % Dispatch a message to create the topic and update metrics
    ro2erl_bridge_server:dispatch(BridgePid, TestMessage),

    % Verify message was dispatched to hub
    ?assertDispatched(TestPid, TestMessage),

    % Get metrics after sending the message
    Metrics = ro2erl_bridge_server:get_metrics(BridgePid),

    % Verify the topic exists
    ?assert(maps:is_key(TopicName, Metrics), "Topic should exist in metrics"),

    % Get topic metrics
    TopicMetrics = maps:get(TopicName, Metrics),

    % Verify dispatched metrics reflect the message size
    DispatchedMetrics = maps:get(dispatched, TopicMetrics),
    ?assert(maps:get(bandwidth, DispatchedMetrics) > 0, "Bandwidth should be greater than 0"),
    ?assert(maps:get(rate, DispatchedMetrics) > 0.0, "Message rate should be greater than 0"),

    % Verify forwarded metrics reflect the message size (as we're connected to a hub)
    ForwardedMetrics = maps:get(forwarded, TopicMetrics),
    ?assert(maps:get(bandwidth, ForwardedMetrics) > 0, "Forwarded bandwidth should be greater than 0"),
    ?assert(maps:get(rate, ForwardedMetrics) > 0.0, "Forwarded message rate should be greater than 0"),

    % Send a second message and verify metrics increase
    ro2erl_bridge_server:dispatch(BridgePid, TestMessage),
    ?assertDispatched(TestPid, TestMessage),

    % Get updated metrics
    UpdatedMetrics = ro2erl_bridge_server:get_metrics(BridgePid),
    UpdatedTopicMetrics = maps:get(TopicName, UpdatedMetrics),

    % Verify metrics have increased
    UpdatedDispatchedMetrics = maps:get(dispatched, UpdatedTopicMetrics),
    UpdatedForwardedMetrics = maps:get(forwarded, UpdatedTopicMetrics),

    % The updated metrics should be higher than the initial metrics
    ?assert(maps:get(bandwidth, UpdatedDispatchedMetrics) >= maps:get(bandwidth, DispatchedMetrics),
           "Bandwidth should increase or stay the same after another message"),
    ?assert(maps:get(rate, UpdatedDispatchedMetrics) >= maps:get(rate, DispatchedMetrics),
           "Message rate should increase or stay the same after another message"),

    % Also verify forwarded metrics have increased
    ?assert(maps:get(bandwidth, UpdatedForwardedMetrics) >= maps:get(bandwidth, ForwardedMetrics),
           "Forwarded bandwidth should increase or stay the same after another message"),
    ?assert(maps:get(rate, UpdatedForwardedMetrics) >= maps:get(rate, ForwardedMetrics),
           "Forwarded message rate should increase or stay the same after another message"),

    % Clear the message queue
    ?assertNoMessage(),

    ok.

metrics_decay_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach the bridge to the test process as a hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),
    ?assertAttached(TestPid, _, BridgePid),

    % Define the test topic and message
    TopicName = <<"test_topic">>,
    MsgSize = 100,
    TestMessage = {test_message, TopicName, true, MsgSize},

    % Dispatch several messages to create the topic and build up metrics
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage),
        ?assertDispatched(TestPid, TestMessage)
    end, lists:seq(1, 5)),

    % Get metrics right after sending the messages
    InitialMetrics = ro2erl_bridge_server:get_metrics(BridgePid),
    TopicMetrics = maps:get(TopicName, InitialMetrics),

    % Get initial bandwidth and rate values
    InitialDispatchBandwidth = maps:get(bandwidth, maps:get(dispatched, TopicMetrics)),
    InitialDispatchRate = maps:get(rate, maps:get(dispatched, TopicMetrics)),
    InitialForwardBandwidth = maps:get(bandwidth, maps:get(forwarded, TopicMetrics)),
    InitialForwardRate = maps:get(rate, maps:get(forwarded, TopicMetrics)),

    % Make sure initial metrics are greater than zero
    ?assert(InitialDispatchBandwidth > 0, "Initial dispatch bandwidth should be > 0"),
    ?assert(InitialDispatchRate > 0.0, "Initial dispatch rate should be > 0"),
    ?assert(InitialForwardBandwidth > 0, "Initial forward bandwidth should be > 0"),
    ?assert(InitialForwardRate > 0.0, "Initial forward rate should be > 0"),

    % Wait a short time to allow metrics to decay
    % The METRIC_WINDOW is 5000ms, so waiting 2.5 seconds should result in ~50% decay
    timer:sleep(2500),

    % Get metrics after waiting
    DecayedMetrics = ro2erl_bridge_server:get_metrics(BridgePid),
    DecayedTopicMetrics = maps:get(TopicName, DecayedMetrics),

    % Get decayed bandwidth and rate values
    DecayedDispatchBandwidth = maps:get(bandwidth, maps:get(dispatched, DecayedTopicMetrics)),
    DecayedDispatchRate = maps:get(rate, maps:get(dispatched, DecayedTopicMetrics)),
    DecayedForwardBandwidth = maps:get(bandwidth, maps:get(forwarded, DecayedTopicMetrics)),
    DecayedForwardRate = maps:get(rate, maps:get(forwarded, DecayedTopicMetrics)),

    % Verify that metrics have decayed but not completely disappeared
    ?assert(DecayedDispatchBandwidth < InitialDispatchBandwidth,
           "Dispatch bandwidth should decay over time"),
    ?assert(DecayedDispatchRate < InitialDispatchRate,
           "Dispatch rate should decay over time"),
    ?assert(DecayedForwardBandwidth < InitialForwardBandwidth,
           "Forward bandwidth should decay over time"),
    ?assert(DecayedForwardRate < InitialForwardRate,
           "Forward rate should decay over time"),

    % Verify metrics haven't decayed to zero yet (should be roughly ~50% of initial)
    ?assert(DecayedDispatchBandwidth > 0, "Dispatch bandwidth shouldn't decay to zero too quickly"),
    ?assert(DecayedDispatchRate > 0.0, "Dispatch rate shouldn't decay to zero too quickly"),
    ?assert(DecayedForwardBandwidth > 0, "Forward bandwidth shouldn't decay to zero too quickly"),
    ?assert(DecayedForwardRate > 0.0, "Forward rate shouldn't decay to zero too quickly"),

    % Wait longer to allow metrics to decay more (almost completely)
    % Waiting another 5 seconds should cause metrics to decay to near-zero
    timer:sleep(5000),

    % Get metrics after waiting longer
    FullyDecayedMetrics = ro2erl_bridge_server:get_metrics(BridgePid),
    FullyDecayedTopicMetrics = maps:get(TopicName, FullyDecayedMetrics),

    % Get final bandwidth and rate values
    FinalDispatchBandwidth = maps:get(bandwidth, maps:get(dispatched, FullyDecayedTopicMetrics)),
    FinalDispatchRate = maps:get(rate, maps:get(dispatched, FullyDecayedTopicMetrics)),
    FinalForwardBandwidth = maps:get(bandwidth, maps:get(forwarded, FullyDecayedTopicMetrics)),
    FinalForwardRate = maps:get(rate, maps:get(forwarded, FullyDecayedTopicMetrics)),

    % Verify that metrics have decayed significantly
    ?assert(FinalDispatchBandwidth < DecayedDispatchBandwidth,
           "Dispatch bandwidth should decay further over time"),
    ?assert(FinalDispatchRate < DecayedDispatchRate,
           "Dispatch rate should decay further over time"),
    ?assert(FinalForwardBandwidth < DecayedForwardBandwidth,
           "Forward bandwidth should decay further over time"),
    ?assert(FinalForwardRate < DecayedForwardRate,
           "Forward rate should decay further over time"),

    ?assert(FinalDispatchBandwidth < InitialDispatchBandwidth * 0.2,
           "Dispatch bandwidth should decay to near zero"),
    ?assert(FinalDispatchRate < InitialDispatchRate * 0.2,
           "Dispatch rate should decay to near zero"),
    ?assert(FinalForwardBandwidth < InitialForwardBandwidth * 0.2,
           "Forward bandwidth should decay to near zero"),
    ?assert(FinalForwardRate < InitialForwardRate * 0.2,
           "Forward rate should decay to near zero"),

    % Clear the message queue
    flush_topic_updates(),
    ?assertNoMessage(),

    ok.

metrics_window_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach the bridge to the test process as a hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),
    ?assertAttached(TestPid, _, BridgePid),

    % Define the test topic and message size
    TopicName = <<"test_topic">>,
    MsgSize = 200,
    Filterable = true,

    % Define the window size in milliseconds (from ro2erl_bridge_metrics macro)
    WindowMs = 5000,

    % First, send a steady stream of messages to establish metrics
    MessageCount = 10,
    TestMessage = {test_message, TopicName, Filterable, MsgSize},

    % Send messages in quick succession
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage),
        ?assertDispatched(TestPid, TestMessage)
    end, lists:seq(1, MessageCount)),

    % Get metrics immediately after sending all messages
    Metrics1 = ro2erl_bridge_server:get_metrics(BridgePid),
    #{TopicName := #{
        dispatched := #{bandwidth := Bandwidth1, rate := Rate1},
        forwarded := #{bandwidth := ForwardBandwidth1, rate := ForwardRate1}
    }} = Metrics1,

    % Ensure metrics were recorded properly
    ?assert(Bandwidth1 > 0, "Initial bandwidth should be greater than 0"),
    ?assert(Rate1 > 0.0, "Initial message rate should be greater than 0"),
    ?assert(ForwardBandwidth1 > 0, "Initial forward bandwidth should be greater than 0"),
    ?assert(ForwardRate1 > 0.0, "Initial forward message rate should be greater than 0"),

    % Wait for half the window time
    timer:sleep(WindowMs div 2),

    % Get metrics after half window time - they should have decreased
    Metrics2 = ro2erl_bridge_server:get_metrics(BridgePid),
    #{TopicName := #{dispatched := #{bandwidth := Bandwidth2}}} = Metrics2,

    % The metrics should have decreased but not to zero
    ?assert(Bandwidth2 < Bandwidth1,
           ?FMT("Bandwidth should decrease after half window (was: ~p, now: ~p)",
                [Bandwidth1, Bandwidth2])),
    ?assert(Bandwidth2 > 0, "Bandwidth should not decay to zero after half window"),

    % Send another burst of messages
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage),
        ?assertDispatched(TestPid, TestMessage)
    end, lists:seq(1, MessageCount)),

    % Get metrics immediately after the second burst
    Metrics3 = ro2erl_bridge_server:get_metrics(BridgePid),
    #{TopicName := #{dispatched := #{bandwidth := Bandwidth3}}} = Metrics3,
    #{TopicName := #{forwarded := #{bandwidth := ForwardBandwidth3}}} = Metrics3,

    % The metrics should have increased compared to the previous reading
    ?assert(Bandwidth3 > Bandwidth2,
            ?FMT("Bandwidth should increase after sending more messages (was: ~p, now: ~p)",
                 [Bandwidth2, Bandwidth3])),

    % Wait for the full window time
    timer:sleep(WindowMs),

    % Get metrics after full window time - they should be close to zero
    Metrics4 = ro2erl_bridge_server:get_metrics(BridgePid),
    #{TopicName := #{dispatched := #{bandwidth := Bandwidth4}}} = Metrics4,

    % The metrics should have decreased significantly
    ?assert(Bandwidth4 < Bandwidth3 * 0.4,
            ?FMT("Bandwidth should decrease significantly after extended window due to exponential decay (was: ~p, now: ~p)",
                 [Bandwidth3, Bandwidth4])),

    % Verify the same pattern for forwarded metrics
    #{TopicName := #{forwarded := #{bandwidth := ForwardBandwidth4}}} = Metrics4,
    ?assert(ForwardBandwidth4 < ForwardBandwidth3 * 0.4,
            ?FMT("Forward bandwidth should decrease significantly after extended window due to exponential decay (was: ~p, now: ~p)",
                 [ForwardBandwidth3, ForwardBandwidth4])),

    % Clean up and verify no unexpected messages
    flush_topic_updates(),
    ?assertNoMessage(),

    ok.

%% Bandwidth Limit Tests
bandwidth_limit_set_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach the bridge to the test process as a hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),
    ?assertAttached(TestPid, _, BridgePid),

    % Define the test topic
    TopicName = <<"test_topic">>,

    % Set an initial bandwidth limit
    InitialLimit = 5000, % 5000 bytes per second
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, TopicName, InitialLimit),

    % Get metrics to verify the topic exists
    Metrics1 = ro2erl_bridge_server:get_metrics(BridgePid),
    ?assert(maps:is_key(TopicName, Metrics1), "Topic should exist in metrics after setting bandwidth"),

    % Send some messages to establish basic metrics
    MsgSize = 200,  % Larger message size
    TestMessage = {test_message, TopicName, true, MsgSize},

    % Send a few messages
    MessageCount = 5,
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage),
        ?assertDispatched(TestPid, TestMessage)
    end, lists:seq(1, MessageCount)),

    % Set a new extremely low bandwidth limit
    NewLimit = 150, % 150 bytes per second (lower than message size)
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, TopicName, NewLimit),

    % Verify limit is effective by sending messages that exceed the limit
    % Each message is 200 bytes, but limit is 150 bytes/sec, so most should be dropped
    MessageCount2 = 30,  % Send more messages

    % Send messages rapidly without waiting for responses
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage)
    end, lists:seq(1, MessageCount2)),

    % Count how many messages were actually forwarded
    timer:sleep(100),
    ForwardedCount = count_forwarded_messages(0),

    % Some messages should have been dropped due to rate limiting
    ?assert(ForwardedCount < MessageCount2,
            ?FMT("Some messages should be dropped (sent: ~p, forwarded: ~p)",
                 [MessageCount2, ForwardedCount])),

    % Set limit to infinity and verify all messages get forwarded
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, TopicName, infinity),

    % Drain any remaining messages
    flush_mailbox(),

    % Send more messages, all should be forwarded with infinity limit
    MessageCount3 = 10,
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage),
        ?assertDispatched(TestPid, TestMessage)
    end, lists:seq(1, MessageCount3)),

    % Verify no more messages are in queue
    ?assertNoMessage(),

    ok.

bandwidth_limit_remove_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach the bridge to the test process as a hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),
    ?assertAttached(TestPid, _, BridgePid),

    % Define the test topic
    TopicName = <<"test_topic">>,
    MsgSize = 200,  % Larger message size
    TestMessage = {test_message, TopicName, true, MsgSize},

    % Set a very low bandwidth limit that will cause message drops
    LowLimit = 200, % 200 bytes per second - only allows 1 message per second
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, TopicName, LowLimit),

    % First send a burst of messages to establish metrics
    % Send messages rapidly - more than the bandwidth limit allows
    % This should cause some messages to be dropped
    MessageCount = 30,  % More messages

    % Send messages rapidly without waiting for responses
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage)
    end, lists:seq(1, MessageCount)),

    % Count how many were actually received
    timer:sleep(100),  % Wait a bit for processing
    CountReceived = count_forwarded_messages(0),

    % We should have received some but not all messages
    ?assert(CountReceived > 0, "Should have received at least some messages"),
    ?assert(CountReceived < MessageCount,
           ?FMT("Should have dropped some messages (sent: ~p, received: ~p)",
                [MessageCount, CountReceived])),

    % Clear mailbox
    flush_mailbox(),

    % Now remove the bandwidth limit by setting it to infinity
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, TopicName, infinity),

    % Wait a moment for the limit change to take effect
    timer:sleep(100),

    % Send messages again - should not drop any with the limit removed
    SecondMessageCount = 10,

    % Send messages all at once
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage)
    end, lists:seq(1, SecondMessageCount)),

    % Wait for all messages to be processed
    timer:sleep(100),
    SecondCountReceived = count_forwarded_messages(0),

    % All messages should have been received with infinity limit
    ?assertEqual(SecondMessageCount, SecondCountReceived,
                ?FMT("All messages should be forwarded with infinity bandwidth limit (sent: ~p, received: ~p)",
                     [SecondMessageCount, SecondCountReceived])),

    % Verify no more messages in queue
    ?assertNoMessage(),

    ok.

non_filterable_always_forward_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach the bridge to the test process as a hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),
    ?assertAttached(TestPid, _, BridgePid),

    % Define a filterable topic and a non-filterable topic
    FilterableTopicName = <<"filterable_topic">>,
    NonFilterableTopicName = <<"non_filterable_topic">>,

    MsgSize = 200,
    FilterableMessage = {test_message, FilterableTopicName, true, MsgSize},
    NonFilterableMessage = {test_message, NonFilterableTopicName, false, MsgSize},

    % Set a very low bandwidth limit for both topics
    % This limit should cause filterable messages to be dropped
    LowLimit = 100, % 100 bytes per second - should drop most messages
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, FilterableTopicName, LowLimit),
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, NonFilterableTopicName, LowLimit),

    % First, send a burst of filterable messages
    FilterableCount = 20,
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, FilterableMessage)
    end, lists:seq(1, FilterableCount)),

    % Count how many filterable messages were received
    timer:sleep(100),
    FilterableReceived = count_forwarded_messages(0),

    % We should have received some but not all filterable messages due to rate limiting
    ?assert(FilterableReceived > 0, "Should have received at least some filterable messages"),
    ?assert(FilterableReceived < FilterableCount,
           ?FMT("Should have dropped some filterable messages (sent: ~p, received: ~p)",
                [FilterableCount, FilterableReceived])),

    % Clear mailbox
    flush_mailbox(),

    % Now send a burst of non-filterable messages
    NonFilterableCount = 20,
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, NonFilterableMessage)
    end, lists:seq(1, NonFilterableCount)),

    % Count how many non-filterable messages were received
    timer:sleep(100),
    NonFilterableReceived = count_forwarded_messages(0),

    % We should have received ALL non-filterable messages despite rate limiting
    ?assertEqual(NonFilterableCount, NonFilterableReceived,
                ?FMT("All non-filterable messages should be forwarded regardless of bandwidth limit (sent: ~p, received: ~p)",
                     [NonFilterableCount, NonFilterableReceived])),

    % Verify no more messages in queue
    ?assertNoMessage(),

    ok.

%% Multiple Topics Tests
multiple_topics_metrics_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach to the hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),
    ?assertAttached(TestPid, _, BridgePid),

    % Create two topics with different properties
    Topic1 = <<"topic1">>,
    Topic2 = <<"topic2">>,
    TestMessage1 = {test_message, Topic1, true, 100},  % Filterable
    TestMessage2 = {test_message, Topic2, false, 100}, % Non-filterable

    % Set different bandwidth limits for each topic
    Limit1 = 150,  % bytes/sec - will cause drops for Topic1
    Limit2 = 300,  % bytes/sec - higher limit for Topic2, but being non-filterable means it won't matter
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, Topic1, Limit1),
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, Topic2, Limit2),

    % Clear any pending messages
    flush_mailbox(),

    % Send rapid messages to both topics
    MessageCount3 = 30,  % Send enough messages to exceed both limits

    % Send to both topics alternately
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage1),
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage2)
    end, lists:seq(1, MessageCount3)),

    % Wait a bit for processing
    timer:sleep(100),

    % Get the metrics right after sending messages for comparison
    #{
        Topic1 := #{dispatched := #{bandwidth := FreshTopic1Bandwidth}},
        Topic2 := #{dispatched := #{bandwidth := FreshTopic2Bandwidth}}
    } = ro2erl_bridge_server:get_metrics(BridgePid),

    #{Topic1 := Topic1Count, Topic2 := Topic2Count} = count_forwarded_topics(#{}),

    % Topic1 (filterable) should have dropped messages due to bandwidth limit
    ?assert(Topic1Count < MessageCount3,
           io_lib:format("Topic1 should drop messages due to bandwidth limit (sent: ~p, received: ~p)",
                        [MessageCount3, Topic1Count])),

    % Topic2 (non-filterable) should have received all messages despite bandwidth limit
    ?assertEqual(MessageCount3, Topic2Count,
                io_lib:format("Topic2 should receive all messages as it's non-filterable (sent: ~p, received: ~p)",
                             [MessageCount3, Topic2Count])),

    % Verify metrics decay independently
    timer:sleep(5000),  % Full window time to ensure decay

    #{
        Topic1 := #{dispatched := #{bandwidth := DecayedTopic1Bandwidth}},
        Topic2 := #{dispatched := #{bandwidth := DecayedTopic2Bandwidth}}
    } = ro2erl_bridge_server:get_metrics(BridgePid),

    ?assert(DecayedTopic1Bandwidth < FreshTopic1Bandwidth * 0.5,
           ?FMT("Topic1 bandwidth should decay significantly (decayed: ~p, fresh: ~p)",
                [DecayedTopic1Bandwidth, FreshTopic1Bandwidth])),
    ?assert(DecayedTopic2Bandwidth < FreshTopic2Bandwidth * 0.5,
           ?FMT("Topic2 bandwidth should decay significantly (decayed: ~p, fresh: ~p)",
                [DecayedTopic2Bandwidth, FreshTopic2Bandwidth])),

    % Verify no unexpected messages besides topic updates
    flush_topic_updates(),
    ?assertNoMessage(),

    ok.

%% Test for hub-initiated bandwidth limit changes
hub_set_bandwidth_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Attach the bridge to the test process as a hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),
    ?assertAttached(TestPid, _, BridgePid),

    % Define the test topic
    TopicName = <<"hub_limited_topic">>,
    MsgSize = 200,  % Message size in bytes
    FilterableMessage = {test_message, TopicName, true, MsgSize},

    % First set a very low bandwidth limit directly from the hub
    LowLimit = 150, % bytes/second - allows approximately one message every 1.3 seconds
    gen_statem:cast(BridgePid, {hub_set_topic_bandwidth, TopicName, LowLimit}),

    % Wait longer for the limit to take effect
    timer:sleep(500),

    % Send a small burst of messages with size greater than the bandwidth limit
    % With low limit, we can at best send 1 message per 1.3 seconds
    MessageCount = 5,
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, FilterableMessage),
        % Add small delay between messages to avoid complete rate limit exhaustion
        timer:sleep(20)
    end, lists:seq(1, MessageCount)),

    % Wait longer to allow messages to be processed
    timer:sleep(300),
    LowLimitForwarded = count_forwarded_messages(0),

    % Should have received at least one message but not all
    ?assert(LowLimitForwarded > 0, "At least some messages should have been forwarded"),
    ?assert(LowLimitForwarded < MessageCount,
           io_lib:format("Should drop some messages with low limit (sent: ~p, forwarded: ~p)",
                        [MessageCount, LowLimitForwarded])),

    % Now set a much higher bandwidth limit from the hub that should allow all messages
    HighLimit = MsgSize * 10, % bytes/second - should allow 10 messages per second
    gen_statem:cast(BridgePid, {hub_set_topic_bandwidth, TopicName, HighLimit}),

    % Wait significantly longer for the higher limit to take effect
    % This gives time for the token bucket to refill
    timer:sleep(1000),

    % Send same number of messages
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, FilterableMessage),
        % Add small delay between messages
        timer:sleep(20)
    end, lists:seq(1, MessageCount)),

    % Wait longer to allow messages to be processed
    timer:sleep(300),
    HighLimitForwarded = count_forwarded_messages(0),

    % With higher limit, we should receive more messages than before
    ?assert(HighLimitForwarded > LowLimitForwarded,
           io_lib:format("Higher limit should allow more messages (low: ~p, high: ~p)",
                        [LowLimitForwarded, HighLimitForwarded])),

    % Now test infinity limit - should always forward all messages
    gen_statem:cast(BridgePid, {hub_set_topic_bandwidth, TopicName, infinity}),

    % Wait for the infinity limit to take effect
    timer:sleep(1000),

    % Send same burst of messages
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, FilterableMessage),
        % Small delay to prevent any rate issues
        timer:sleep(20)
    end, lists:seq(1, MessageCount)),

    % Wait for processing
    timer:sleep(300),
    InfinityLimitForwarded = count_forwarded_messages(0),

    % With infinity limit, we should receive all messages
    ?assertEqual(MessageCount, InfinityLimitForwarded,
                io_lib:format("Infinity limit should allow all messages (sent: ~p, forwarded: ~p)",
                             [MessageCount, InfinityLimitForwarded])),

    % Verify no unexpected messages (besides topic updates)
    flush_topic_updates(),
    ?assertNoDispatchMessage(),

    ok.

%% Test for dispatch callback functionality
dispatch_callback_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Create a simulated hub
    HubPid = TestPid,

    % Attach to the hub
    ok = ro2erl_bridge_server:attach(BridgePid, HubPid),
    ?assertAttached(HubPid, _, BridgePid),

    TestMessage1 = {test_message, <<"From Hub">>},

    % Send a message from the hub to the bridge
    hub_dispatch(BridgePid, TestMessage1),

    % Verify the message was dispatched locally via our callback
    ?assertDispatchedLocally(TestMessage1),

    TestMessage2 = {test_message, <<"Another Message">>},

    % Send another message
    hub_dispatch(BridgePid, TestMessage2),
    ?assertDispatchedLocally(TestMessage2),

    % Verify no unexpected messages (besides topic updates)
    flush_topic_updates(),
    ?assertNoDispatchMessage(),

    ok.

%% Test for topic update message handling
topic_update_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),
    BridgePid = proplists:get_value(bridge_pid, Config),

    % First, flush any existing messages
    % flush_mailbox(),

    % Attach the bridge to the test process as a hub
    ok = ro2erl_bridge_server:attach(BridgePid, TestPid),
    ?assertAttached(TestPid, _, BridgePid),

    % Send messages to create some topics with different characteristics
    Topic1 = <<"topic1">>,
    Topic2 = <<"topic2">>,
    Topic1FilterableMsg = {test_message, Topic1, true, 100},   % Filterable, small
    Topic2NonFilterableMsg = {test_message, Topic2, false, 500}, % Non-filterable, larger

    % Set different bandwidth limits for the topics
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, Topic1, 1000),
    ok = ro2erl_bridge_server:set_topic_bandwidth(BridgePid, Topic2, 2000),

    % Send some messages to establish metrics for the topics
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, Topic1FilterableMsg),
        ?assertDispatched(TestPid, Topic1FilterableMsg),
        ro2erl_bridge_server:dispatch(BridgePid, Topic2NonFilterableMsg),
        ?assertDispatched(TestPid, Topic2NonFilterableMsg)
    end, lists:seq(1, 5)),

    % Now wait for the first topic update message (default period is 1000ms)
    FirstTopics = ?assertTopicUpdated(TestPid, #{Topic1 := _, Topic2 := _}),

    % Verify topic metadata is correct
    #{Topic1 := Topic1Info} = FirstTopics,
    #{Topic2 := Topic2Info} = FirstTopics,

    % Check that topics have the correct filterable flag
    ?assertEqual(true, maps:get(filterable, Topic1Info)),
    ?assertEqual(false, maps:get(filterable, Topic2Info)),

    % Check that bandwidth limits are correctly reported
    ?assertEqual(1000, maps:get(bandwidth_limit, Topic1Info)),
    ?assertEqual(2000, maps:get(bandwidth_limit, Topic2Info)),

    % Check that metrics are included and have the expected structure
    ?assert(maps:is_key(metrics, Topic1Info)),
    ?assert(maps:is_key(metrics, Topic2Info)),

    #{metrics := Topic1Metrics} = Topic1Info,
    #{metrics := Topic2Metrics} = Topic2Info,

    % Verify metrics structure
    ?assert(maps:is_key(dispatched, Topic1Metrics)),
    ?assert(maps:is_key(forwarded, Topic1Metrics)),
    ?assert(maps:is_key(dispatched, Topic2Metrics)),
    ?assert(maps:is_key(forwarded, Topic2Metrics)),

    % Wait for a second update to verify periodic updates
    ?assertTopicUpdated(TestPid, #{Topic1 := _, Topic2 := _}),

    % Send more messages to one topic and verify updates reflect the changes
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, Topic1FilterableMsg),
        ?assertDispatched(TestPid, Topic1FilterableMsg)
    end, lists:seq(1, 5)),

    % Wait for another update
    ?assertTopicUpdated(TestPid, #{Topic1 := _, Topic2 := _}),

    % Verify no unexpected messages (besides topic updates)
    flush_topic_updates(),
    ?assertNoDispatchMessage(),

    ok.

%% Custom payload test
custom_payload_test(Config) ->
    TestPid = self(),
    register(current_test, TestPid),

    % Get the bridge PID
    BridgePid = proplists:get_value(bridge_pid, Config),

    % Create a hub process
    Hub = spawn(fun() -> hub_proc(TestPid) end),

    % Attach to the hub
    ok = ro2erl_bridge_server:attach(BridgePid, Hub),
    ?assertConnected(BridgePid),
    ?assertAttached(Hub, _, BridgePid),

    % Test case: Standard message with implicit payload (using original message)
    OriginalMsg = {test_message, <<"test_topic">>, true, 100},
    ro2erl_bridge_server:dispatch(BridgePid, OriginalMsg),

    % Verify hub received the original message as payload
    ?assertDispatched(Hub, OriginalMsg),

    % Test case: Message with explicit custom payload
    CustomPayloadMsg = {test_message, <<"test_topic2">>, true, 200, <<"custom_payload">>},
    ExpectedPayload = <<"custom_payload">>,
    ro2erl_bridge_server:dispatch(BridgePid, CustomPayloadMsg),

    % Verify hub received the custom payload
    ?assertDispatched(Hub, ExpectedPayload),

    % Cleanup
    ok = ro2erl_bridge_server:detach(BridgePid, Hub),
    ?assertDetached(Hub, BridgePid),

    Hub ! stop,
    ?assertNoMessage(),

    ok.


%=== HUB API IMPLEMENTATION ===================================================

%% Test Hub API Implementation - These are called by the bridge
attach(HubPid, BridgeId, BridgePid) ->
    current_test ! {bridge_attach, HubPid, BridgeId, BridgePid},
    ok.

detach(HubPid, BridgePid) ->
    current_test ! {bridge_detach, HubPid, BridgePid},
    ok.

dispatch(HubPid, SenderPid, Timestamp, Message) ->
    current_test ! {bridge_dispatch, HubPid, SenderPid, Timestamp, Message},
    ok.

update_topics(HubPid, BridgePid, Topics) ->
    current_test ! {bridge_update_topics, HubPid, BridgePid, Topics},
    ok.

%=== HELPER FUNCTIONS =========================================================

%% Flush all messages from the process mailbox
flush_mailbox() ->
    receive
        _Any -> flush_mailbox()
    after 0 ->
        ok
    end.

%% Flush the mailbox topic update messages
flush_topic_updates() ->
    receive
        {bridge_update_topics, _, _, _} -> flush_topic_updates()
    after 0 ->
        ok
    end.

%% Count forwarded messages in the process mailbox, but ignoring topic updates
count_forwarded_messages(Count) ->
    receive
        {bridge_dispatch, _, _, _, _} ->
            count_forwarded_messages(Count + 1);
        {bridge_update_topics, _, _, _} ->
            % Ignore topic updates
            count_forwarded_messages(Count)
    after 0 ->
        Count
    end.

%% Count forwarded messages per topic in the process mailbox
count_forwarded_topics(Counts) ->
    receive
        {bridge_dispatch, _, _, _, {test_message, TopicName, _, _}} ->
            NewCount = maps:get(TopicName, Counts, 0) + 1,
            count_forwarded_topics(Counts#{TopicName => NewCount});
        {bridge_update_topics, _, _, _} ->
            % Ignore topic updates
            count_forwarded_topics(Counts)
    after 0 ->
        Counts
    end.

hub_dispatch(BridgePid, Message) ->
    gen_statem:cast(BridgePid, {hub_dispatch, erlang:system_time(millisecond), Message}).

hub_proc(TestPid) ->
    receive
        {bridge_attach, _HubPid, _BridgeId, _BridgePid} = Msg ->
            TestPid ! Msg,
            hub_proc(TestPid);
        {bridge_detach, _HubPid, _BridgePid} = Msg ->
            TestPid ! Msg,
            hub_proc(TestPid);
        {bridge_dispatch, _HubPid, _SenderPid, _Timestamp, _Message} = Msg ->
            TestPid ! Msg,
            hub_proc(TestPid);
        stop ->
            ok
    end.

%% Testing message processor that expects test messages
%% in the format {test_message, TopicName, Filterable, Size, CustomPayload} or similar formats
%% If CustomPayload is provided, it's used; otherwise the original message is used as payload
test_message_processor({test_message, TopicName, Filterable, Size, CustomPayload}) ->
    % Format with custom payload specified
    {topic, TopicName, Filterable, Size, CustomPayload};
test_message_processor({test_message, TopicName, Filterable, Size}) ->
    % Format without custom payload - use message as its own payload
    {topic, TopicName, Filterable, Size, {test_message, TopicName, Filterable, Size}};
test_message_processor(Message) ->
    % Fallback for other message formats - use message as its own payload
    {topic, <<"unknown">>, true, 100, Message}.

%% Testing dispatch callback function
test_dispatch_callback(Message) ->
    current_test ! {local_dispatch, Message},
    ok.
