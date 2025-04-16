-module(ro2erl_bridge_metrics_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").


%=== EXPORTS ===================================================================

%% Test server callbacks
-export([
    all/0,
    suite/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases
-export([
    initial_update_test/1,
    rolling_window_decay_test/1,
    complete_decay_test/1,
    bandwidth_calculation_test/1,
    message_rate_calculation_test/1,
    multiple_updates_test/1,
    action_decision_test/1,
    finite_limit_action_test/1,
    infinite_limit_action_test/1,
    action_recovery_test/1,
    metrics_retrieval_test/1,
    zero_time_delta_test/1,
    complex_chain_test/1,
    realistic_metrics_test/1
]).


%=== MACROS ====================================================================

-define(METRIC_WINDOW, 5000).  % Match the window size used in the module

%% Custom macro to compare floats with a tolerance
-define(assertSimilar(Expected, Actual, Message),
    ?assert(abs((Expected) - (Actual)) =< 0.001,
        ?FMT(Message ++ "; expected: ~p; got: ~p", [Expected, Actual]))).

%% Format string macro
-define(FMT(Fmt, Args), lists:flatten(io_lib:format(Fmt, Args))).


%=== CT CALLBACKS ==============================================================

suite() ->
    [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

all() -> [
    initial_update_test,
    rolling_window_decay_test,
    complete_decay_test,
    bandwidth_calculation_test,
    message_rate_calculation_test,
    multiple_updates_test,
    action_decision_test,
    finite_limit_action_test,
    infinite_limit_action_test,
    action_recovery_test,
    metrics_retrieval_test,
    zero_time_delta_test,
    complex_chain_test,
    realistic_metrics_test
].


%=== TEST CASES ================================================================

%% Test initial update with a message
initial_update_test(_Config) ->
    % Initial state, first message of size 100 at time 1000
    {Action, Bytes, MsgCount, Bandwidth, MsgRate} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0.0, infinity, 100),

    % Verify basic updates
    ?assertEqual(forward, Action, "Initial action should be forward with infinity limit"),
    ?assertEqual(100, Bytes, "Invalid initial bytes"),
    ?assertSimilar(1.0, MsgCount, "Invalid initial message count"),
    ?assertEqual(20, Bandwidth, "Invalid initial bandwidth"),
    ?assertSimilar(0.2, MsgRate, "Invalid initial message rate").

%% Test decay of values over time (rolling window)
rolling_window_decay_test(_Config) ->
    % Initial update
    {Action1, Bytes1, MsgCount1, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0.0, infinity, 1000),
    ?assertEqual(forward, Action1, "Action should be forward with infinity limit"),
    ?assertEqual(1000, Bytes1, "Invalid initial bytes"),
    ?assertSimilar(1.0, MsgCount1, "Invalid initial message count"),

    % After 2500ms (half window), should have decayed by approximately 50%
    {Action2, Bytes2, MsgCount2, _, _} =
        ro2erl_bridge_metrics:update(1000, 3500, 1000, 1.0, infinity, undefined),
    ?assertEqual(undefined, Action2, "Action should be undefined when MsgSize is undefined"),
    ?assertEqual(500, Bytes2, "Invalid decayed bytes"),
    ?assertSimilar(0.5, MsgCount2, "Invalid decayed message count").

%% Test complete decay after full window period
complete_decay_test(_Config) ->
    % Initial update
    {Action1, Bytes1, MsgCount1, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 1000, 10.0, infinity, 100),
    ?assertEqual(forward, Action1, "Action should be forward with infinity limit"),
    ?assertEqual(1100, Bytes1, "Invalid initial bytes"),
    ?assertSimilar(11.0, MsgCount1, "Invalid initial message count"),

    % After full window (5000ms) plus a little more, should have decayed completely
    {Action2, Bytes2, MsgCount2, Bandwidth, MsgRate} =
        ro2erl_bridge_metrics:update(1000, 6500, 1100, 11.0, infinity, undefined),
    ?assertEqual(undefined, Action2, "Action should be undefined when MsgSize is undefined"),
    ?assertEqual(0, Bytes2, "Bytes did not decay completely"),
    ?assertSimilar(0.0, MsgCount2, "Messages did not decay completely"),
    ?assertEqual(0, Bandwidth, "Invalid bandwidth after complete decay"),
    ?assertSimilar(0.0, MsgRate, "Invalid message rate after complete decay").

%% Test bandwidth calculation with various message sizes
bandwidth_calculation_test(_Config) ->
    % 1MB message at time 1000
    {_, _, _, Bandwidth1, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, infinity, 1000000),
    ?assertEqual(200000, Bandwidth1, "Invalid bandwidth for 1MB message"),

    % 10KB message at time 2000
    {_, _, _, Bandwidth2, _} =
        ro2erl_bridge_metrics:update(2000, 2000, 0, 0, infinity, 10000),
    ?assertEqual(2000, Bandwidth2, "Invalid bandwidth for 10KB message").

%% Test message rate calculation
message_rate_calculation_test(_Config) ->
    % 10 messages added at once
    {_, _, _, _, MsgRate} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 10.0, infinity, 100),
    ?assertSimilar(2.2, MsgRate, "Invalid message rate for 11 msgs in 5sec window").

%% Test multiple sequential updates
multiple_updates_test(_Config) ->
    % Initial update
    {Action1, Bytes1, MsgCount1, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0.0, infinity, 100),
    ?assertEqual(forward, Action1, "Action should be forward with infinity limit"),
    ?assertEqual(100, Bytes1, "Invalid initial bytes"),
    ?assertSimilar(1.0, MsgCount1, "Invalid initial message count"),

    % Second update 1 second later
    {Action2, Bytes2, MsgCount2, Bandwidth, MsgRate} =
        ro2erl_bridge_metrics:update(1000, 2000, Bytes1, MsgCount1, infinity, 200),
    ?assertEqual(forward, Action2, "Action should be forward with infinity limit"),

    % Expect: 100 bytes decayed by 20% + 200 new bytes = 280 bytes
    ?assertEqual(280, Bytes2, "Invalid bytes after decay and new message"),
    ?assertSimilar(1.8, MsgCount2, "Invalid message count after decay and new message"),
    ?assertEqual(56, Bandwidth, "Invalid bandwidth after update"),
    ?assertSimilar(0.36, MsgRate, "Invalid message rate after update").

%% Test action-based decision making
action_decision_test(_Config) ->
    % Define a fixed limit
    Limit = 1000, % 1000 bytes/second
    WindowCapacity = round(Limit * ?METRIC_WINDOW / 1000), % 5000 bytes total window capacity

    % First message: small enough to be forwarded
    {Action1, Bytes1, MsgCount1, BW1, Rate1} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0.0, Limit, 500),
    ?assertEqual(forward, Action1, "Small message should be forwarded"),
    ?assertEqual(500, Bytes1, "Bytes should be updated with message size"),
    ?assertSimilar(1.0, MsgCount1, "Message count should be updated"),
    ?assertEqual(100, BW1, "Bandwidth should be updated"),
    ?assertSimilar(0.2, Rate1, "Message rate should be updated"),

    % Second message: also small enough to be forwarded
    {Action2, Bytes2, MsgCount2, BW2, Rate2} =
        ro2erl_bridge_metrics:update(1000, 1000, Bytes1, MsgCount1, Limit, 500),
    ?assertEqual(forward, Action2, "Second small message should be forwarded"),
    ?assertEqual(1000, Bytes2, "Bytes should be updated with message size"),
    ?assertSimilar(2.0, MsgCount2, "Message count should increase"),
    ?assertEqual(200, BW2, "Bandwidth should increase"),
    ?assertSimilar(0.4, Rate2, "Message rate should increase"),

    % Third message: would exceed capacity, should be dropped
    {Action3, Bytes3, MsgCount3, BW3, Rate3} =
        ro2erl_bridge_metrics:update(1000, 1000, Bytes2, MsgCount2, Limit, WindowCapacity),
    ?assertEqual(drop, Action3, "Message exceeding capacity should be dropped"),
    ?assertEqual(1000, Bytes3, "Bytes should NOT include dropped message"),
    ?assertSimilar(2.0, MsgCount3, "Message count should NOT increase for dropped message"),
    ?assertEqual(200, BW3, "Bandwidth should NOT increase for dropped message"),
    ?assertSimilar(0.4, Rate3, "Message rate should NOT increase for dropped message"),

    % Check with infinity limit - should always forward
    {Action4, Bytes4, MsgCount4, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 1000000, 1000.0, infinity, 1000000),
    ?assertEqual(forward, Action4, "Message with infinity limit should always be forwarded"),
    ?assertEqual(2000000, Bytes4, "Bytes should be updated with infinity limit"),
    ?assertSimilar(1001.0, MsgCount4, "Message count should be updated with infinity limit"),

    % Check with undefined message size
    {Action5, Bytes5, MsgCount5, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0.0, Limit, undefined),
    ?assertEqual(undefined, Action5, "Action should be undefined when MsgSize is undefined"),
    ?assertEqual(0, Bytes5, "Bytes should not change with undefined message size"),
    ?assertSimilar(0.0, MsgCount5, "Message count should not change with undefined message size").

%% Test the forwarding action with finite limits
finite_limit_action_test(_Config) ->
    % Set a limit of 1MB/sec
    Limit = 1000000,
    WindowCapacity = round(Limit * ?METRIC_WINDOW / 1000),

    % Initial state with no data
    {Action1, Bytes1, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, Limit, undefined),
    ?assertEqual(undefined, Action1, "Action should be undefined for metrics-only check"),
    ?assertEqual(0, Bytes1, "No bytes should be registered"),

    % Add 100KB and check forward action
    {Action2, Bytes2, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, Limit, 100000),
    ?assertEqual(forward, Action2, "Should forward message within capacity"),
    ?assertEqual(100000, Bytes2, "Bytes should be updated correctly"),

    % Add a message that exceeds remaining capacity
    {Action3, _, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, WindowCapacity - 1000, 0, Limit, 2000),
    ?assertEqual(drop, Action3, "Should drop message that exceeds capacity").

%% Test with infinite limit capacity - all messages should be forwarded
infinite_limit_action_test(_Config) ->
    % Initial state with no data
    {Action1, _, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, infinity, undefined),
    ?assertEqual(undefined, Action1, "Action should be undefined for metrics-only check"),

    % Add data and check forwarded action
    {Action2, _, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, infinity, 100000),
    ?assertEqual(forward, Action2, "Message with infinity limit should be forwarded"),

    % Try with very large message
    {Action3, _, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 1000000, 0, infinity, 10000000),
    ?assertEqual(forward, Action3, "Large message with infinity limit should be forwarded").

%% Test that action recovers after decay
action_recovery_test(_Config) ->
    Limit = 100000, % 100KB/sec
    WindowCapacity = round(Limit * ?METRIC_WINDOW / 1000), % Total capacity in window
    LargeMessageSize = WindowCapacity - 1000, % Almost fills capacity

    % Fill almost to capacity
    {Action1, Bytes1, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, Limit, LargeMessageSize),
    ?assertEqual(forward, Action1, "Large message within capacity should be forwarded"),
    ?assertEqual(LargeMessageSize, Bytes1, "Bytes should be updated with message size"),

    % Try to add message that exceeds remaining capacity
    {Action2, _, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, Bytes1, 1, Limit, 2000),
    ?assertEqual(drop, Action2, "Message exceeding capacity should be dropped"),

    % Wait for decay and try again
    {Action3, _, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 3500, Bytes1, 1, Limit, 2000),
    ?assertEqual(forward, Action3, "After decay, message should be forwarded").

%% Test retrieval of metrics without adding a message
metrics_retrieval_test(_Config) ->
    % Add initial data
    {Action1, Bytes1, MsgCount1, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0.0, infinity, 1000),
    ?assertEqual(forward, Action1, "Initial action should be forward"),
    ?assertEqual(1000, Bytes1, "Invalid initial bytes"),
    ?assertSimilar(1.0, MsgCount1, "Invalid initial message count"),

    % Retrieve metrics after 1 second without adding data
    {Action2, Bytes2, MsgCount2, Bandwidth, MsgRate} =
        ro2erl_bridge_metrics:update(1000, 2000, Bytes1, MsgCount1, infinity, undefined),
    ?assertEqual(undefined, Action2, "Action should be undefined for metrics-only check"),

    % Expect decay but no new data
    ?assertEqual(800, Bytes2, "Invalid decayed bytes"),
    ?assertSimilar(0.8, MsgCount2, "Invalid decayed message count"),
    ?assertEqual(160, Bandwidth, "Invalid bandwidth after decay"),
    ?assertSimilar(0.16, MsgRate, "Invalid message rate after decay").

%% Test update with zero time delta
zero_time_delta_test(_Config) ->
    % Initial data
    {Action1, Bytes1, MsgCount1, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 500, 5.0, infinity, undefined),
    ?assertEqual(undefined, Action1, "Action should be undefined for metrics-only check"),
    ?assertEqual(500, Bytes1, "Initial bytes should remain unchanged"),
    ?assertSimilar(5.0, MsgCount1, "Initial message count should remain unchanged"),

    % Update with same timestamp and add data
    {Action2, Bytes2, MsgCount2, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, Bytes1, MsgCount1, infinity, 100),
    ?assertEqual(forward, Action2, "Action should be forward with infinity limit"),
    ?assertEqual(600, Bytes2, "Bytes should increase by message size with no decay"),
    ?assertSimilar(6.0, MsgCount2, "Message count should increase by 1 with no decay").

%% Test complex chain of events using a playlist
complex_chain_test(_Config) ->
    % Define a playlist of actions to test various scenarios
    Playlist = [
        % Initial burst of messages
        {update, 1000, infinity, forward, ?LINE},  % 1MB message
        {update, 500, infinity, forward, ?LINE},   % 500KB message
        {update, 200, infinity, forward, ?LINE},   % 200KB message

        % Wait and check decay
        {wait, 2500, ?LINE},  % Wait half window
        {check, 170, 0.3, ?LINE},  % Should have decayed by ~50%

        % Test rate limiting
        {update, 1000, 2000, forward, ?LINE},  % 1MB message with 2MB/s limit
        {check, 370, 0.5, ?LINE},  % Should be at limit
        % For drop test, use a much larger message that will definitely exceed the limit
        {update, 10000, 2000, drop, ?LINE},   % Try to add more (10MB), should be dropped

        % Wait for partial recovery
        {wait, 1000, ?LINE},
        {check, 296, 0.4, ?LINE},  % Should have recovered some (20% decay after 1 second)

        % Test complete decay
        {wait, 5000, ?LINE},  % Wait full window
        {check, 0, 0.0, ?LINE},  % Should be completely decayed

        % Test burst after decay
        {update, 2000, infinity, forward, ?LINE},  % 2MB message
        {check, 400, 0.2, ?LINE},  % Should show new burst

        % Test multiple small messages
        {update, 100, infinity, forward, ?LINE},
        {update, 100, infinity, forward, ?LINE},
        {update, 100, infinity, forward, ?LINE},
        {check, 460, 0.8, ?LINE},  % Should accumulate

        % Final decay check
        {wait, 5000, ?LINE},
        {check, 0, 0.0, ?LINE}  % Should decay completely
    ],

    % Execute playlist starting at time 1000
    execute_playlist(1000, 1000, 0, 0.0, Playlist).

%% Test realistic scenarios with careful validation of bandwidth and rate values
realistic_metrics_test(_Config) ->
    % Define playlists to test realistic scenarios focusing on bandwidth and rate

    %% Scenario 1: Constant data rate (100KB/s)
    ct:pal("~n===== Scenario 1: Constant data rate ====="),
    ConstantRatePlaylist = [
        % Start with empty state
        {update, 100000, infinity, forward, ?LINE},   % 100KB message at T0
        {check, 20000, 0.2, ?LINE},                   % Initial bandwidth calculation
        {wait, 1000, ?LINE},                          % Wait 1 second
        {update, 100000, infinity, forward, ?LINE},   % 100KB message at T0+1s
        {check, 36000, 0.36, ?LINE},                  % 180KB/5s after 20% decay + new message
        {wait, 1000, ?LINE},                          % Wait 1 second
        {update, 100000, infinity, forward, ?LINE},   % 100KB message at T0+2s
        {check, 48800, 0.488, ?LINE},                 % Bandwidth continues to increase
        {wait, 1000, ?LINE},                          % Wait 1 second
        {update, 100000, infinity, forward, ?LINE},   % 100KB message at T0+3s
        {check, 59040, 0.5904, ?LINE},                % Bandwidth continues to increase
        {wait, 1000, ?LINE},                          % Wait 1 second
        {update, 100000, infinity, forward, ?LINE},   % 100KB message at T0+4s
        {check, 67232, 0.67232, ?LINE},               % Bandwidth continues to increase
        {wait, 1000, ?LINE},                          % Wait 1 second
        {update, 100000, infinity, forward, ?LINE},   % 100KB message at T0+5s
        {check, 73786, 0.73786, ?LINE}                % Approaching steady state (~80KB/s)
    ],
    T0 = 10000,
    execute_playlist(T0, T0, 0, 0.0, ConstantRatePlaylist),

    %% Scenario 2: Traffic spike and recovery
    ct:pal("~n===== Scenario 2: Traffic spike and recovery ====="),
    SpikeRecoveryPlaylist = [
        % Start with low rate traffic
        {update, 10000, infinity, forward, ?LINE},    % 10KB message at T1
        {check, 2000, 0.2, ?LINE},                    % Initial bandwidth
        {wait, 1000, ?LINE},                          % Wait 1 second
        {update, 10000, infinity, forward, ?LINE},    % 10KB message at T1+1s
        {check, 3600, 0.36, ?LINE},                   % Low bandwidth established

        % Sudden spike - 10x traffic (very short interval)
        {wait, 100, ?LINE},                           % Wait 100ms
        {update, 100000, infinity, forward, ?LINE},   % Spike: 100KB message at T1+1.1s
        {check, 23528, 0.5528, ?LINE},                % Bandwidth jumps

        % Recovery - back to normal rate
        {wait, 900, ?LINE},                           % Wait 900ms (total 1s since spike)
        {update, 10000, infinity, forward, ?LINE},    % 10KB message at T1+2.1s
        {check, 21293, 0.6529, ?LINE},                % Still elevated bandwidth
        {wait, 1000, ?LINE},                          % Wait 1 second
        {update, 10000, infinity, forward, ?LINE},    % 10KB message at T1+3.1s
        {check, 19034, 0.7226, ?LINE},                % Bandwidth slowly decreasing
        {wait, 1000, ?LINE},                          % Wait 1 second
        {update, 10000, infinity, forward, ?LINE},    % 10KB message at T1+4.1s
        {check, 17228, 0.7781, ?LINE},                % Continuing to normalize
        {wait, 1000, ?LINE},                          % Wait 1 second
        {update, 10000, infinity, forward, ?LINE},    % 10KB message at T1+5.1s
        {check, 15782, 0.8225, ?LINE}                 % Bandwidth stabilizing but still elevated
    ],
    T1 = 20000,
    execute_playlist(T1, T1, 0, 0.0, SpikeRecoveryPlaylist),

    %% Scenario 3: Rate limiting with burst capacity
    ct:pal("~n===== Scenario 3: Rate limiting ====="),
    % The limit used in the playlist is 40000 bytes/second (40KB/s)
    RateLimitPlaylist = [
        % Start with higher traffic rate that will exceed limits
        {update, 100000, 40000, forward, ?LINE},     % 100KB message at T2
        {check, 20000, 0.2, ?LINE},                  % Initial bandwidth/rate
        {wait, 1000, ?LINE},                         % Wait 1 second
        {update, 100000, 40000, forward, ?LINE},     % 100KB message at T2+1s
        {check, 36000, 0.36, ?LINE},                 % Building up
        {wait, 1000, ?LINE},                         % Wait 1 second
        {update, 100000, 40000, drop, ?LINE},        % 100KB message at T2+2s - exceeds limit
        {check, 28800, 0.288, ?LINE},                % Bandwidth after decay, no new data added

        % Message gets limited (dropped) at this point as we've reached the limit
        {wait, 1000, ?LINE},                         % Wait 1 second
        {update, 100000, 40000, drop, ?LINE},        % 100KB message at T2+3s - will be limited
        {check, 23040, 0.2304, ?LINE},               % Lower after decay, no new data

        % Continue trying with rate-limited traffic
        {wait, 1000, ?LINE},                         % Wait 1 second
        {update, 100000, 40000, forward, ?LINE},     % 100KB message at T2+4s - now under limit due to decay
        {check, 38432, 0.38432, ?LINE}               % Final values with new message after decay
    ],
    T3 = 40000,
    execute_playlist(T3, T3, 0, 0.0, RateLimitPlaylist),

    ok.


%=== HELPER FUNCTIONS ==========================================================

%% Execute a playlist of actions for testing the metrics module
-spec execute_playlist(Now, LastUpdate, Bytes, MsgCount, Playlist) -> ok
  when Now :: non_neg_integer(),
       LastUpdate :: non_neg_integer(),
       Bytes :: non_neg_integer(),
       MsgCount :: float(),
       Playlist :: [
        {update, non_neg_integer(), non_neg_integer() | infinity, forward | drop | undefined, integer()}
        | {wait, non_neg_integer(), integer()}
        | {check, non_neg_integer(), float(), integer()}
       ].
execute_playlist(_Now, _LastUpdate, _Bytes, _MsgCount, []) ->
    ok;
execute_playlist(Now, LastUpdate, Bytes, MsgCount,
                 [{update, Size, Limit, ExpectedAction, Line} | Rest]) ->
    {Action, NewBytes, NewMsgCount, Bandwidth, MsgRate} =
        ro2erl_bridge_metrics:update(LastUpdate, Now, Bytes, MsgCount, Limit, Size),
    ?assertEqual(ExpectedAction, Action,
        ?FMT("Invalid action at line ~p - expected:~p, got:~p with size:~p limit:~p",
             [Line, ExpectedAction, Action, Size, Limit])),
    ct:pal("Update: bytes=~p count=~p bw=~p rate=~p", [NewBytes, NewMsgCount, Bandwidth, MsgRate]),
    execute_playlist(Now, Now, NewBytes, NewMsgCount, Rest);
execute_playlist(Now, LastUpdate, Bytes, MsgCount, [{wait, Time, _Line} | Rest]) ->
    ct:pal("Wait: ~p ms from time ~p with bytes=~p count=~p", [Time, Now, Bytes, MsgCount]),
    execute_playlist(Now + Time, LastUpdate, Bytes, MsgCount, Rest);
execute_playlist(Now, LastUpdate, Bytes, MsgCount,
                 [{check, ExpectedBandwidth, ExpectedRate, Line} | Rest]) ->
    {Action, NewBytes, NewMsgCount, Bandwidth, MsgRate} =
        ro2erl_bridge_metrics:update(LastUpdate, Now, Bytes, MsgCount, infinity, undefined),
    ?assertEqual(undefined, Action,
        ?FMT("Invalid action at line ~p", [Line])),
    ?assertEqual(ExpectedBandwidth, Bandwidth,
        ?FMT("Invalid bandwidth at line ~p - expected:~p, got:~p", [Line, ExpectedBandwidth, Bandwidth])),
    ?assertSimilar(ExpectedRate, MsgRate,
        ?FMT("Invalid message rate at line ~p - expected:~p, got:~p", [Line, ExpectedRate, MsgRate])),
    ct:pal("Check: bytes=~p count=~p bw=~p rate=~p", [NewBytes, NewMsgCount, Bandwidth, MsgRate]),
    execute_playlist(Now, Now, NewBytes, NewMsgCount, Rest).
