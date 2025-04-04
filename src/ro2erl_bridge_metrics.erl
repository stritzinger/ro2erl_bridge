-module(ro2erl_bridge_metrics).

-moduledoc """
Token bucket metrics implementation for the bridge.

This module provides functions to calculate and update metrics using a token bucket
algorithm with a rolling window. It is designed to be easily testable by allowing
the caller to provide timestamps instead of using system time.
""".

%=== EXPORTS ===================================================================

% API functions
-export([update/6]).


%=== MACROS ====================================================================

%% Rate limiting configuration
-define(METRIC_WINDOW, 5000).  % 5 second window for rate calculations
-define(RATE_THRESHOLD, 0.01).


%=== API FUNCTIONS =============================================================

-doc """
Update metrics using a token bucket algorithm with a rolling window.

This function implements a token bucket algorithm with a rolling window to track
bandwidth and message rates. It supports both updating with new messages and
decaying existing values over time.

The function tracks two main metrics:
- Message count: Increments by 1 for each message, regardless of its size
- Bandwidth: Accumulates the total bytes of all messages

Parameters:
- LastUpdate: Timestamp of last update in milliseconds
- Now: Current timestamp in milliseconds
- Bytes: Current accumulated bytes in the window
- MsgCount: Current message count in the window
- Limit: Bandwidth limit in bytes per second (byte/s). When set to infinity, no limit is applied.
- MsgSize: Size of new message in bytes, or undefined for decay-only updates

If MsgSize is undefined, the metrics will not be updated with new data. The function
will only decay existing values and refill the buckets based on the time elapsed
since the last update.

Returns:
- NewBytes: Updated accumulated bytes after decay and new message
- NewMsgCount: Updated message count after decay and new message
- Bandwidth: Current bandwidth in bytes per second
- MsgRate: Current message rate in messages per second
- Capacity: Remaining capacity in bytes for the current window, or infinity if no limit
""".
-spec update(LastUpdate :: non_neg_integer(),
             Now :: non_neg_integer(),
             Bytes :: non_neg_integer(),
             MsgCount :: float(),
             Limit :: non_neg_integer() | infinity,
             MsgSize :: undefined | non_neg_integer()) ->
    {
        NewBytes :: non_neg_integer(),
        NewMsgCount :: float(),
        Bandwidth :: non_neg_integer(),
        MsgRate :: float(),
        Capacity :: non_neg_integer() | infinity
    }.
update(LastUpdate, Now, Bytes, MsgCount, Limit, MsgSize) ->
    % Calculate time elapsed since last update
    Delta = Now - LastUpdate,

    % Decay existing values based on time elapsed
    % This implements the rolling window effect
    DecayedBytes = max(0, round(Bytes - Bytes * Delta / ?METRIC_WINDOW)),
    DecayedMsgs = max(0.0, MsgCount - MsgCount * Delta / ?METRIC_WINDOW),

    % Add new message if size is provided
    {NewBytes, NewMsgCount} = case MsgSize of
        undefined ->
            {DecayedBytes, DecayedMsgs};
        Size when is_integer(Size), Size >= 0 ->
            {DecayedBytes + Size, DecayedMsgs + 1.0}
    end,

    % Calculate current rates per-second
    Bandwidth = round(NewBytes * 1000 / ?METRIC_WINDOW),
    MsgRate = case NewMsgCount * 1000.0 / ?METRIC_WINDOW of
        R when R >= ?RATE_THRESHOLD -> R;
        _ -> 0.0
    end,

    % Calculate remaining capacity based on limit
    Capacity = case Limit of
        infinity -> infinity;
        L when is_integer(L), L > 0 ->
            max(0, round(L * ?METRIC_WINDOW / 1000 - NewBytes))
    end,

    {NewBytes, NewMsgCount, Bandwidth, MsgRate, Capacity}.
