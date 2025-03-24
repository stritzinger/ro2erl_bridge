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
-export([dispatch/2]).


%=== TYPES =====================================================================

%% Message types for protocol communication
-type attach_msg() :: {attach, binary(), pid()}.
-type detach_msg() :: {detach, pid()}.
-type dispatch_msg() :: {dispatch, term()}.

-export_type([attach_msg/0, detach_msg/0, dispatch_msg/0]).


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
    gen_statem:cast(HubPid, {attach, BridgeId, ServicePid}),
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
    gen_statem:cast(HubPid, {detach, ServicePid}),
    ok.

-doc """
Dispatches a message to the hub

Sends a message to the hub for distribution to other connected services.

### Parameters:
- HubPid: pid() - Process ID of the hub service
- Message: term() - The message to dispatch

### Example:
```
> ro2erl_bridge_hub:dispatch(HubPid, {topic, "/sensor", data}).
ok
```
""".
-spec dispatch(HubPid :: pid(), Message :: term()) -> ok.
dispatch(HubPid, Message) when is_pid(HubPid) ->
    gen_statem:cast(HubPid, {dispatch, Message}),
    ok.
