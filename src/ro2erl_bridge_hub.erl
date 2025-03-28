-module(ro2erl_bridge_hub).

-moduledoc """
Hub communication abstraction for ro2erl_bridge

This module provides an abstraction layer for communicating with a ro2erl_hub
service running on a different Erlang node. Since the bridge doesn't have
access to the ro2erl_hub application, this module uses gen_statem calls
to communicate with the hub.
""".

%% API functions
-export([attach/3]).
-export([detach/2]).
-export([dispatch/4]).
-export([update_topics/3]).


%=== TYPES =====================================================================

%% Message types for protocol communication
-type bridge_attach_msg() :: {bridge_attach, binary(), pid()}.
-type bridge_detach_msg() :: {bridge_detach, pid()}.
-type bridge_dispatch_msg() :: {bridge_dispatch, pid(), integer(), term()}.
-type bridge_update_topics_msg() :: {bridge_update_topics, pid(), #{
    TopicName :: binary() => #{
        filterable := boolean(),
        bandwidth_limit := non_neg_integer() | infinity,
        metrics := #{
            dispatched := #{bandwidth := non_neg_integer(), rate := float()},
            forwarded := #{bandwidth := non_neg_integer(), rate := float()}
        }
    }
}}.

-export_type([
    bridge_attach_msg/0,
    bridge_detach_msg/0,
    bridge_dispatch_msg/0,
    bridge_update_topics_msg/0
]).


%=== API FUNCTIONS =============================================================

-doc """
Attaches a service to the hub

Sends an attach message to the hub to register a service.

### Parameters:
- HubPid: pid() - Process ID of the hub service
- BridgeId: binary() - Opaque identifier for the bridge
- BridgePid: pid() - Process ID of the bridge service to attach

### Example:
```
> ro2erl_bridge_hub:attach(HubPid, <<"bridge1">>, self()).
ok
```
""".
-spec attach(HubPid :: pid(), BridgeId :: binary(), BridgePid :: pid()) -> ok.
attach(HubPid, BridgeId, BridgePid) when is_pid(HubPid), is_binary(BridgeId), is_pid(BridgePid) ->
    gen_statem:cast(HubPid, {bridge_attach, BridgeId, BridgePid}),
    ok.

-doc """
Detaches a service from the hub

Sends a detach message to the hub to unregister a service.

### Parameters:
- HubPid: pid() - Process ID of the hub service
- BridgePid: pid() - Process ID of the bridge service to detach

### Example:
```
> ro2erl_bridge_hub:detach(HubPid, self()).
ok
```
""".
-spec detach(HubPid :: pid(), BridgePid :: pid()) -> ok.
detach(HubPid, BridgePid) when is_pid(HubPid), is_pid(BridgePid) ->
    gen_statem:cast(HubPid, {bridge_detach, BridgePid}),
    ok.

-doc """
Dispatches a message to the hub

Sends a message to the hub for distribution to other connected services.

### Parameters:
- HubPid: pid() - Process ID of the hub service
- SenderPid: pid() - Process ID of the sender (or undefined for system messages)
- Timestamp: integer() - When the message was sent (in milliseconds)
- Message: term() - The message to dispatch

### Example:
```
> ro2erl_bridge_hub:dispatch(HubPid, self(), erlang:system_time(millisecond), {topic, "/sensor", data}).
ok
```
""".
-spec dispatch(HubPid :: pid(), SenderPid :: pid() | undefined, Timestamp :: integer(), Message :: term()) -> ok.
dispatch(HubPid, SenderPid, Timestamp, Message)
  when is_pid(HubPid), is_integer(Timestamp), (SenderPid =:= undefined orelse is_pid(SenderPid)) ->
    gen_statem:cast(HubPid, {bridge_dispatch, SenderPid, Timestamp, Message}),
    ok.

-doc """
Updates the topic information to the hub

Sends information about known topics to the hub including filterable status,
bandwidth limits, and metrics.

### Parameters:
- HubPid: pid() - Process ID of the hub service
- BridgePid: pid() - Process ID of the bridge service
- Topics: map() - Map of topic information where keys are topic names and values are maps containing:
  - filterable: boolean() - Whether the topic can be filtered by bandwidth limits
  - bandwidth_limit: non_neg_integer() | infinity - Current bandwidth limit in bytes/s
  - metrics: map() - Current metrics for the topic as returned by get_topic_metrics

### Example:
```
> Topics = #{
    <<"/sensor">> => #{
        filterable => true,
        bandwidth_limit => 1024,
        metrics => #{
            dispatched => #{bandwidth => 512, rate => 2.5},
            forwarded => #{bandwidth => 256, rate => 1.2}
        }
    }
  },
> ro2erl_bridge_hub:update_topics(HubPid, self(), Topics).
ok
```
""".
-spec update_topics(HubPid :: pid(), BridgePid :: pid(), Topics :: #{binary() => #{
    filterable := boolean(),
    bandwidth_limit := non_neg_integer() | infinity,
    metrics := #{
        dispatched := #{bandwidth := non_neg_integer(), rate := float()},
        forwarded := #{bandwidth := non_neg_integer(), rate := float()}
    }
}}) -> ok.
update_topics(HubPid, BridgePid, Topics) when is_pid(HubPid), is_pid(BridgePid), is_map(Topics) ->
    gen_statem:cast(HubPid, {bridge_update_topics, BridgePid, Topics}),
    ok.
