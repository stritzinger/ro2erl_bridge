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


%=== TYPES =====================================================================

%% Message types for protocol communication
-type bridge_attach_msg() :: {bridge_attach, binary(), pid()}.
-type bridge_detach_msg() :: {bridge_detach, pid()}.
-type bridge_dispatch_msg() :: {bridge_dispatch, pid(), integer(), term()}.

-export_type([bridge_attach_msg/0, bridge_detach_msg/0, bridge_dispatch_msg/0]).


%=== API FUNCTIONS =============================================================

-doc """
Attaches a service to the hub

Sends an attach message to the hub to register a service.

### Parameters:
- HubPid: pid() - Process ID of the hub service
- BridgeId: binary() - Opaque identifier for the bridge
- ServicePid: pid() - Process ID of the service to attach

### Example:
```
> ro2erl_bridge_hub:attach(HubPid, <<"bridge1">>, self()).
ok
```
""".
-spec attach(HubPid :: pid(), BridgeId :: binary(), ServicePid :: pid()) -> ok.
attach(HubPid, BridgeId, ServicePid) when is_pid(HubPid), is_binary(BridgeId), is_pid(ServicePid) ->
    gen_statem:cast(HubPid, {bridge_attach, BridgeId, ServicePid}),
    ok.

-doc """
Detaches a service from the hub

Sends a detach message to the hub to unregister a service.

### Parameters:
- HubPid: pid() - Process ID of the hub service
- ServicePid: pid() - Process ID of the service to detach

### Example:
```
> ro2erl_bridge_hub:detach(HubPid, self()).
ok
```
""".
-spec detach(HubPid :: pid(), ServicePid :: pid()) -> ok.
detach(HubPid, ServicePid) when is_pid(HubPid), is_pid(ServicePid) ->
    gen_statem:cast(HubPid, {bridge_detach, ServicePid}),
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
