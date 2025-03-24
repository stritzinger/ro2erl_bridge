-module(ro2erl_bridge).

-moduledoc """
ro2erl_bridge public API

This module provides the public API for dispatching ROS2 messages.
The only supported format for now is the rosie_rclerl format.
""".

%% API functions
-export([dispatch/1]).


%=== API FUNCTIONS =============================================================

-doc """
Send a message from local ROS2 network to the hub

This should be called when a message is received from rosie_rclerl
that needs to be forwarded to the hub, which will then distribute it
to other connected bridges.

### Example:
```
> ro2erl_bridge:dispatch(Message).
ok
```
""".
-spec dispatch(Message :: term()) -> ok.
dispatch(Message) ->
    ro2erl_bridge_server:dispatch(Message).
