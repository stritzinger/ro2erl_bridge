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
    finite_limit_capacity_test/1,
    infinite_limit_capacity_test/1,
    capacity_reduction_test/1,
    metrics_retrieval_test/1,
    zero_time_delta_test/1,
    complex_chain_test/1
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
    finite_limit_capacity_test,
    infinite_limit_capacity_test,
    capacity_reduction_test,
    metrics_retrieval_test,
    zero_time_delta_test,
    complex_chain_test
].


%=== TEST CASES ================================================================

%% Test initial update with a message
initial_update_test(_Config) ->
    % Initial state, first message of size 100 at time 1000
    {Bytes, MsgCount, Bandwidth, MsgRate, Remaining} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0.0, infinity, 100),

    % Verify basic updates
    ?assertEqual(100, Bytes, "Invalid initial bytes"),
    ?assertSimilar(1.0, MsgCount, "Invalid initial message count"),
    ?assertEqual(20, Bandwidth, "Invalid initial bandwidth"),
    ?assertSimilar(0.2, MsgRate, "Invalid initial message rate"),
    ?assertEqual(infinity, Remaining, "Invalid remaining capacity").

%% Test decay of values over time (rolling window)
rolling_window_decay_test(_Config) ->
    % Initial update
    {Bytes1, MsgCount1, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0.0, infinity, 1000),
    ?assertEqual(1000, Bytes1, "Invalid initial bytes"),
    ?assertSimilar(1.0, MsgCount1, "Invalid initial message count"),

    % After 2500ms (half window), should have decayed by approximately 50%
    {Bytes2, MsgCount2, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 3500, 1000, 1.0, infinity, undefined),
    ?assertEqual(500, Bytes2, "Invalid decayed bytes"),
    ?assertSimilar(0.5, MsgCount2, "Invalid decayed message count").

%% Test complete decay after full window period
complete_decay_test(_Config) ->
    % Initial update
    {Bytes1, MsgCount1, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 1000, 10.0, infinity, 100),
    ?assertEqual(1100, Bytes1, "Invalid initial bytes"),
    ?assertSimilar(11.0, MsgCount1, "Invalid initial message count"),

    % After full window (5000ms) plus a little more, should have decayed completely
    {Bytes2, MsgCount2, Bandwidth, MsgRate, _} =
        ro2erl_bridge_metrics:update(1000, 6500, 1100, 11.0, infinity, undefined),
    ?assertEqual(0, Bytes2, "Bytes did not decay completely"),
    ?assertSimilar(0.0, MsgCount2, "Messages did not decay completely"),
    ?assertEqual(0, Bandwidth, "Invalid bandwidth after complete decay"),
    ?assertSimilar(0.0, MsgRate, "Invalid message rate after complete decay").

%% Test bandwidth calculation with various message sizes
bandwidth_calculation_test(_Config) ->
    % 1MB message at time 1000
    {_, _, Bandwidth1, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, infinity, 1000000),
    ?assertEqual(200000, Bandwidth1, "Invalid bandwidth for 1MB message"),

    % 10KB message at time 2000
    {_, _, Bandwidth2, _, _} =
        ro2erl_bridge_metrics:update(2000, 2000, 0, 0, infinity, 10000),
    ?assertEqual(2000, Bandwidth2, "Invalid bandwidth for 10KB message").

%% Test message rate calculation
message_rate_calculation_test(_Config) ->
    % 10 messages added at once
    {_, _, _, MsgRate, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 10.0, infinity, 100),
    ?assertSimilar(2.2, MsgRate, "Invalid message rate for 11 msgs in 5sec window").

%% Test multiple sequential updates
multiple_updates_test(_Config) ->
    % Initial update
    {Bytes1, MsgCount1, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0.0, infinity, 100),
    ?assertEqual(100, Bytes1, "Invalid initial bytes"),
    ?assertSimilar(1.0, MsgCount1, "Invalid initial message count"),

    % Second update 1 second later
    {Bytes2, MsgCount2, Bandwidth, MsgRate, _} =
        ro2erl_bridge_metrics:update(1000, 2000, Bytes1, MsgCount1, infinity, 200),

    % Expect: 100 bytes decayed by 20% + 200 new bytes = 280 bytes
    ?assertEqual(280, Bytes2, "Invalid bytes after decay and new message"),
    ?assertSimilar(1.8, MsgCount2, "Invalid message count after decay and new message"),
    ?assertEqual(56, Bandwidth, "Invalid bandwidth after update"),
    ?assertSimilar(0.36, MsgRate, "Invalid message rate after update").

%% Test capacity calculation with finite limit
finite_limit_capacity_test(_Config) ->
    % Limit of 1MB/sec
    Limit = 1000000,

    % Initial state with no data
    {_, _, _, _, Remaining1} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, Limit, undefined),
    ExpectedCapacity = round(Limit * ?METRIC_WINDOW / 1000),
    ?assertEqual(ExpectedCapacity, Remaining1, "Invalid initial capacity"),

    % Add 100KB and check remaining capacity
    {_, _, _, _, Remaining2} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, Limit, 100000),
    ?assertEqual(ExpectedCapacity - 100000, Remaining2, "Invalid remaining capacity after message").

%% Test capacity calculation with infinite limit
infinite_limit_capacity_test(_Config) ->
    % Initial state with no data
    {_, _, _, _, Remaining1} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, infinity, undefined),
    ?assertEqual(infinity, Remaining1, "Invalid initial capacity with infinite limit"),

    % Add data and check remaining capacity remains infinity
    {_, _, _, _, Remaining2} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, infinity, 100000),
    ?assertEqual(infinity, Remaining2, "Invalid remaining capacity after message with infinite limit").

%% Test that capacity reduces as bucket fills and recovers as it empties
capacity_reduction_test(_Config) ->
    Limit = 100000, % 100KB/sec
    ExpectedCapacity = round(Limit * ?METRIC_WINDOW / 1000), % Total capacity in window

    % Fill half the capacity
    {Bytes1, _, _, _, Remaining1} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0, Limit, ExpectedCapacity div 2),
    ?assertEqual(ExpectedCapacity - Bytes1, Remaining1, "Invalid capacity after filling half"),

    % Wait for half the window for partial recovery
    {_, _, _, _, Remaining2} =
        ro2erl_bridge_metrics:update(1000, 3500, Bytes1, 1, Limit, undefined),
    ?assert(Remaining2 > Remaining1, "Capacity did not increase as bucket emptied").

%% Test retrieval of metrics without adding a message
metrics_retrieval_test(_Config) ->
    % Add initial data
    {Bytes1, MsgCount1, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 0, 0.0, infinity, 1000),
    ?assertEqual(1000, Bytes1, "Invalid initial bytes"),
    ?assertSimilar(1.0, MsgCount1, "Invalid initial message count"),

    % Retrieve metrics after 1 second without adding data
    {Bytes2, MsgCount2, Bandwidth, MsgRate, _} =
        ro2erl_bridge_metrics:update(1000, 2000, Bytes1, MsgCount1, infinity, undefined),

    % Expect decay but no new data
    ?assertEqual(800, Bytes2, "Invalid decayed bytes"),
    ?assertSimilar(0.8, MsgCount2, "Invalid decayed message count"),
    ?assertEqual(160, Bandwidth, "Invalid bandwidth after decay"),
    ?assertSimilar(0.16, MsgRate, "Invalid message rate after decay").

%% Test update with zero time delta
zero_time_delta_test(_Config) ->
    % Initial data
    {Bytes1, MsgCount1, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, 500, 5.0, infinity, undefined),
    ?assertEqual(500, Bytes1, "Initial bytes should remain unchanged"),
    ?assertSimilar(5.0, MsgCount1, "Initial message count should remain unchanged"),

    % Update with same timestamp and add data
    {Bytes2, MsgCount2, _, _, _} =
        ro2erl_bridge_metrics:update(1000, 1000, Bytes1, MsgCount1, infinity, 100),
    ?assertEqual(600, Bytes2, "Bytes should increase by message size with no decay"),
    ?assertSimilar(6.0, MsgCount2, "Message count should increase by 1 with no decay").

%% Test complex chain of events using a playlist
complex_chain_test(_Config) ->
    % Define a playlist of actions to test various scenarios
    Playlist = [
        % Initial burst of messages
        {update, 1000, infinity, infinity, ?LINE},  % 1MB message
        {update, 500, infinity, infinity, ?LINE},   % 500KB message
        {update, 200, infinity, infinity, ?LINE},   % 200KB message

        % Wait and check decay
        {wait, 2500, ?LINE},  % Wait half window
        {check, 170, 0.3, ?LINE},  % Should have decayed by ~50%

        % Test rate limiting
        {update, 1000, 2000, 8150, ?LINE},  % 1MB message with 2MB/s limit
        {check, 370, 0.5, ?LINE},  % Should be at limit
        {update, 500, 2000, 7650, ?LINE},   % Try to add more

        % Wait for partial recovery
        {wait, 1000, ?LINE},
        {check, 376, 0.56, ?LINE},  % Should have recovered some

        % Test complete decay
        {wait, 5000, ?LINE},  % Wait full window
        {check, 0, 0.0, ?LINE},  % Should be completely decayed

        % Test burst after decay
        {update, 2000, infinity, infinity, ?LINE},  % 2MB message
        {check, 400, 0.2, ?LINE},  % Should show new burst

        % Test multiple small messages
        {update, 100, infinity, infinity, ?LINE},
        {update, 100, infinity, infinity, ?LINE},
        {update, 100, infinity, infinity, ?LINE},
        {check, 460, 0.8, ?LINE},  % Should accumulate

        % Final decay check
        {wait, 5000, ?LINE},
        {check, 0, 0.0, ?LINE}  % Should decay completely
    ],

    % Execute playlist starting at time 1000
    execute_playlist(1000, 1000, 0, 0.0, Playlist).


%=== HELPER FUNCTIONS ==========================================================

%% Execute a playlist of actions for testing the metrics module
-spec execute_playlist(Now, LastUpdate, Bytes, MsgCount, Playlist) -> ok
  when Now :: non_neg_integer(),
       LastUpdate :: non_neg_integer(),
       Bytes :: non_neg_integer(),
       MsgCount :: float(),
       Playlist :: [
        {update, non_neg_integer(), float(), infinity | non_neg_integer(), infinity | non_neg_integer(), integer()}
        | {wait, non_neg_integer(), integer()}
        | {check, non_neg_integer(), float(), integer()}
       ].
execute_playlist(_Now, _LastUpdate, _Bytes, _MsgCount, []) ->
    ok;
execute_playlist(Now, LastUpdate, Bytes, MsgCount,
                 [{update, Size, Limit, ExpectedCapacity, Line} | Rest]) ->
    {NewBytes, NewMsgCount, _, _, Capacity} =
        ro2erl_bridge_metrics:update(LastUpdate, Now, Bytes, MsgCount, Limit, Size),
    ?assertEqual(ExpectedCapacity, Capacity,
        ?FMT("Invalid remaining capacity at line ~p", [Line])),
    execute_playlist(Now, Now, NewBytes, NewMsgCount, Rest);
execute_playlist(Now, LastUpdate, Bytes, MsgCount, [{wait, Time, _Line} | Rest]) ->
    execute_playlist(Now + Time, LastUpdate, Bytes, MsgCount, Rest);
execute_playlist(Now, LastUpdate, Bytes, MsgCount,
                 [{check, ExpectedBandwidth, ExpectedRate, Line} | Rest]) ->
    {NewBytes, NewMsgCount, Bandwidth, MsgRate, _} =
        ro2erl_bridge_metrics:update(LastUpdate, Now, Bytes, MsgCount, infinity, undefined),
    ?assertEqual(ExpectedBandwidth, Bandwidth,
        ?FMT("Invalid bandwidth at line ~p", [Line])),
    ?assertSimilar(ExpectedRate, MsgRate,
        ?FMT("Invalid message rate at line ~p", [Line])),
    execute_playlist(Now, Now, NewBytes, NewMsgCount, Rest).
