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
    multiple_topics_metrics_test/1
]).

%% Test Hub API - Used by the bridge
-export([
    attach/3,
    detach/2,
    dispatch/4,
    test_message_processor/1
]).


%=== MACROS ===================================================================

%% Assertion macros
-define(assertAttached(HUB_PID, BRIDGE_ID, BRIDGE_PID), fun() ->
    receive
        {bridge_attach, HUB_PID, BRIDGE_ID, BRIDGE_PID} -> ok
    after 1000 ->
        ct:fail({attach_timeout, ?MODULE, ?LINE})
    end
end()).

-define(assertDetached(HUB_PID, BRIDGE_PID), fun() ->
    receive
        {bridge_detach, HUB_PID, BRIDGE_PID} -> ok
    after 1000 ->
        ct:fail({detach_timeout, ?MODULE, ?LINE})
    end
end()).

-define(assertDispatched(HUB_PID, MESSAGE), fun() ->
    receive
        {bridge_dispatch, HUB_PID, SenderPid, Timestamp, Msg}
          when Msg == MESSAGE, is_pid(SenderPid), is_integer(Timestamp) -> ok
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

-define(assertConnected(BRIDGE_PID), fun() ->
    ?assertEqual(true, ro2erl_bridge_server:is_connected(BRIDGE_PID))
end()).

-define(assertDisconnected(BRIDGE_PID), fun() ->
    ?assertEqual(false, ro2erl_bridge_server:is_connected(BRIDGE_PID))
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
    multiple_topics_metrics_test
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
    {ok, BridgePid} = ro2erl_bridge_server:start_link(?MODULE, fun ?MODULE:test_message_processor/1),

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

    % Verify that metrics have decayed significantly (should be very close to zero)
    ?assert(FinalDispatchBandwidth < DecayedDispatchBandwidth,
           "Dispatch bandwidth should decay further over time"),
    ?assert(FinalDispatchRate < DecayedDispatchRate,
           "Dispatch rate should decay further over time"),
    ?assert(FinalForwardBandwidth < DecayedForwardBandwidth,
           "Forward bandwidth should decay further over time"),
    ?assert(FinalForwardRate < DecayedForwardRate,
           "Forward rate should decay further over time"),

    % The values should be very close to zero after full decay time
    ?assert(FinalDispatchBandwidth < InitialDispatchBandwidth * 0.1,
           "Dispatch bandwidth should decay to near zero"),
    ?assert(FinalDispatchRate < InitialDispatchRate * 0.1,
           "Dispatch rate should decay to near zero"),
    ?assert(FinalForwardBandwidth < InitialForwardBandwidth * 0.1,
           "Forward bandwidth should decay to near zero"),
    ?assert(FinalForwardRate < InitialForwardRate * 0.1,
           "Forward rate should decay to near zero"),

    % Clear the message queue
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
    TopicMetrics1 = maps:get(TopicName, Metrics1),

    % Extract the bandwidth and rate values
    DispatchMetrics1 = maps:get(dispatched, TopicMetrics1),
    Bandwidth1 = maps:get(bandwidth, DispatchMetrics1),
    Rate1 = maps:get(rate, DispatchMetrics1),

    % Ensure metrics were recorded properly
    ?assert(Bandwidth1 > 0, "Initial bandwidth should be greater than 0"),
    ?assert(Rate1 > 0.0, "Initial message rate should be greater than 0"),

    % Wait for half the window time
    timer:sleep(WindowMs div 2),

    % Get metrics after half window time - they should have decreased
    Metrics2 = ro2erl_bridge_server:get_metrics(BridgePid),
    TopicMetrics2 = maps:get(TopicName, Metrics2),
    DispatchMetrics2 = maps:get(dispatched, TopicMetrics2),
    Bandwidth2 = maps:get(bandwidth, DispatchMetrics2),
    % Rate2 = maps:get(rate, DispatchMetrics2),

    % The metrics should have decreased but not to zero
    ?assert(Bandwidth2 < Bandwidth1,
           io_lib:format("Bandwidth should decrease after half window (was: ~p, now: ~p)",
                        [Bandwidth1, Bandwidth2])),
    ?assert(Bandwidth2 > 0, "Bandwidth should not decay to zero after half window"),

    % Send another burst of messages
    lists:foreach(fun(_) ->
        ro2erl_bridge_server:dispatch(BridgePid, TestMessage),
        ?assertDispatched(TestPid, TestMessage)
    end, lists:seq(1, MessageCount)),

    % Get metrics immediately after the second burst
    Metrics3 = ro2erl_bridge_server:get_metrics(BridgePid),
    TopicMetrics3 = maps:get(TopicName, Metrics3),
    DispatchMetrics3 = maps:get(dispatched, TopicMetrics3),
    Bandwidth3 = maps:get(bandwidth, DispatchMetrics3),

    % The metrics should have increased compared to the previous reading
    ?assert(Bandwidth3 > Bandwidth2,
           io_lib:format("Bandwidth should increase after sending more messages (was: ~p, now: ~p)",
                        [Bandwidth2, Bandwidth3])),

    % Wait for the full window time
    timer:sleep(WindowMs),

    % Get metrics after full window time - they should be close to zero
    Metrics4 = ro2erl_bridge_server:get_metrics(BridgePid),
    TopicMetrics4 = maps:get(TopicName, Metrics4),
    DispatchMetrics4 = maps:get(dispatched, TopicMetrics4),
    Bandwidth4 = maps:get(bandwidth, DispatchMetrics4),

    % The metrics should have decreased significantly
    ?assert(Bandwidth4 < Bandwidth3 * 0.2,
           io_lib:format("Bandwidth should decrease to near-zero after full window (was: ~p, now: ~p)",
                        [Bandwidth3, Bandwidth4])),

    % Verify the same pattern for forwarded metrics
    ForwardMetrics1 = maps:get(forwarded, TopicMetrics1),
    ForwardBandwidth1 = maps:get(bandwidth, ForwardMetrics1),
    ?assert(ForwardBandwidth1 > 0, "Initial forward bandwidth should be greater than 0"),

    ForwardMetrics4 = maps:get(forwarded, TopicMetrics4),
    ForwardBandwidth4 = maps:get(bandwidth, ForwardMetrics4),
    ?assert(ForwardBandwidth4 < ForwardBandwidth1 * 0.2,
           io_lib:format("Forward bandwidth should decrease to near-zero after full window (was: ~p, now: ~p)",
                        [ForwardBandwidth1, ForwardBandwidth4])),

    % Clean up and verify no unexpected messages
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
            io_lib:format("Some messages should be dropped (sent: ~p, forwarded: ~p)",
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
           io_lib:format("Should have dropped some messages (sent: ~p, received: ~p)",
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
                io_lib:format("All messages should be forwarded with infinity bandwidth limit (sent: ~p, received: ~p)",
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
           io_lib:format("Should have dropped some filterable messages (sent: ~p, received: ~p)",
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
                io_lib:format("All non-filterable messages should be forwarded regardless of bandwidth limit (sent: ~p, received: ~p)",
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
    FreshMetrics = ro2erl_bridge_server:get_metrics(BridgePid),
    FreshTopic1Metrics = maps:get(Topic1, FreshMetrics),
    FreshTopic1Dispatched = maps:get(dispatched, FreshTopic1Metrics),
    FreshTopic1Bandwidth = maps:get(bandwidth, FreshTopic1Dispatched),
    FreshTopic2Metrics = maps:get(Topic2, FreshMetrics),
    FreshTopic2Dispatched = maps:get(dispatched, FreshTopic2Metrics),
    FreshTopic2Bandwidth = maps:get(bandwidth, FreshTopic2Dispatched),

    % Count messages received for each topic
    TopicCounts = count_forwarded_topics(#{}),
    Topic1Count = maps:get(Topic1, TopicCounts, 0),
    Topic2Count = maps:get(Topic2, TopicCounts, 0),

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
    Metrics3 = ro2erl_bridge_server:get_metrics(BridgePid),

    DecayedTopic1Metrics = maps:get(Topic1, Metrics3),
    DecayedTopic2Metrics = maps:get(Topic2, Metrics3),

    DecayedTopic1Dispatched = maps:get(dispatched, DecayedTopic1Metrics),
    DecayedTopic1Bandwidth = maps:get(bandwidth, DecayedTopic1Dispatched),
    DecayedTopic2Dispatched = maps:get(dispatched, DecayedTopic2Metrics),
    DecayedTopic2Bandwidth = maps:get(bandwidth, DecayedTopic2Dispatched),

    ?assert(DecayedTopic1Bandwidth < FreshTopic1Bandwidth,
           io_lib:format("Topic1 bandwidth should decay independently (decayed: ~p, fresh: ~p)",
                        [DecayedTopic1Bandwidth, FreshTopic1Bandwidth])),
    ?assert(DecayedTopic2Bandwidth < FreshTopic2Bandwidth,
           io_lib:format("Topic2 bandwidth should decay independently (decayed: ~p, fresh: ~p)",
                        [DecayedTopic2Bandwidth, FreshTopic2Bandwidth])),

    % Verify no unexpected messages
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

%=== HELPER FUNCTIONS =========================================================

%% Clear all messages from the process mailbox
flush_mailbox() ->
    receive
        _Any -> flush_mailbox()
    after 0 ->
        ok
    end.

%% Count forwarded messages in the process mailbox
count_forwarded_messages(Count) ->
    receive
        {bridge_dispatch, _, _, _, _} ->
            count_forwarded_messages(Count + 1)
    after 0 ->
        Count
    end.

%% Count forwarded messages per topic in the process mailbox
count_forwarded_topics(Counts) ->
    receive
        {bridge_dispatch, _, _, _, {test_message, TopicName, _, _}} ->
            NewCount = maps:get(TopicName, Counts, 0) + 1,
            count_forwarded_topics(Counts#{TopicName => NewCount})
    after 0 ->
        Counts
    end.

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
%% in the format {test_message, TopicName, Filterable, Size}
%% or the simpler format {test_message, TopicName} for backward compatibility
test_message_processor({test_message, TopicName, Filterable, Size}) ->
    {topic, TopicName, Filterable, Size};
test_message_processor(_Message) ->
    % Fallback for other message formats
    {topic, <<"unknown">>, true, 100}.
