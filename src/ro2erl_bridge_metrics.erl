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

Return Values:
- Action: Indicates how to handle the message:
  - 'forward': The message should be processed and forwarded. Returned when:
    - MsgSize is defined AND
    - Either Limit is infinity OR
    - Adding the message would not exceed the calculated capacity
  - 'drop': The message should be discarded. Returned when:
    - MsgSize is defined AND
    - Limit is a finite number AND
    - Adding the message would exceed the calculated capacity
  - 'undefined': No action needed. Returned when:
    - MsgSize is undefined (decay-only update)
- NewBytes: Updated accumulated bytes after decay and new message
- NewMsgCount: Updated message count after decay and new message
- Bandwidth: Current bandwidth in bytes per second
- MsgRate: Current message rate in messages per second

The capacity of the token bucket is calculated as: Limit * WINDOW_SIZE / 1000
For example, with a Limit of 1000 bytes/s and a window of 5000ms, the capacity
would be 5000 bytes in the window.

### Examples:
```
% Update metrics with a new 100-byte message
{Action, NewBytes, NewCount, BW, Rate} = ro2erl_bridge_metrics:update(
    LastTime, erlang:system_time(millisecond), OldBytes, OldCount, 10000, 100)

% Just decay existing metrics without a new message
{undefined, DecayedBytes, DecayedCount, CurrentBW, CurrentRate} =
    ro2erl_bridge_metrics:update(LastTime, erlang:system_time(millisecond),
    OldBytes, OldCount, Limit, undefined)
```
""".
-spec update(LastUpdate :: non_neg_integer(),
             Now :: non_neg_integer(),
             Bytes :: non_neg_integer(),
             MsgCount :: float(),
             Limit :: non_neg_integer() | infinity,
             MsgSize :: undefined | non_neg_integer()) ->
    {
        Action :: forward | drop | undefined,
        NewBytes :: non_neg_integer(),
        NewMsgCount :: float(),
        Bandwidth :: non_neg_integer(),
        MsgRate :: float()
    }.
update(LastUpdate, Now, Bytes, MsgCount, Limit, MsgSize) ->
    % Calculate time elapsed since last update
    Delta = Now - LastUpdate,

    % Decay existing values based on time elapsed
    % This implements the rolling window effect
    DecayedBytes = max(0, round(Bytes - Bytes * Delta / ?METRIC_WINDOW)),
    DecayedMsgs = max(0.0, MsgCount - MsgCount * Delta / ?METRIC_WINDOW),

    % Determine if we should forward this message based on limit
    {Action, NewBytes, NewMsgCount} = case {MsgSize, Limit} of
        {undefined, _} ->
            % Just querying metrics, no message to process
            {undefined, DecayedBytes, DecayedMsgs};
        {_, infinity} ->
            % No limit, always forward
            {forward, DecayedBytes + MsgSize, DecayedMsgs + 1.0};
        {Size, L} when is_integer(Size), is_integer(L) ->
            % Calculate window capacity
            Capacity = round(L * ?METRIC_WINDOW / 1000),
            % Check if message would exceed capacity
            ShouldForward = DecayedBytes + Size =< Capacity,
            case ShouldForward of
                true ->
                    % Forward and count the message
                    {forward, DecayedBytes + Size, DecayedMsgs + 1.0};
                false ->
                    % Drop the message, but still return the decayed values
                    {drop, DecayedBytes, DecayedMsgs}
            end
    end,

    % Calculate current rates per-second
    Bandwidth = round(NewBytes * 1000 / ?METRIC_WINDOW),
    MsgRate = case NewMsgCount * 1000.0 / ?METRIC_WINDOW of
        R when R >= ?RATE_THRESHOLD -> R;
        _ -> 0.0
    end,

    {Action, NewBytes, NewMsgCount, Bandwidth, MsgRate}.
