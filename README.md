# ro2erl_bridge

ROS2-Erlang Bridge Component for Target-X.

## Overview

The ro2erl_bridge is a component of the Target-X system that serves as a bridge between ROS2/DDS networks and an Erlang-based distributed system. It is designed to operate at robot sites, interfacing with the local ROS2/DDS network and communicating with a central hub.

This component works in "Dispatch Mode," where it receives parsed messages from rosie_rclerl client, applies filtering rules, and forwards them to the hub.

## Features

- Hub discovery and automatic registration
- Message forwarding to/from the hub
- Message filtering (future)
- Customizable local dispatch callback

## Installation

ro2erl_bridge is designed to be used as a dependency within your own Erlang application:

```erlang
%% rebar.config
{deps, [
    {ro2erl_bridge, {git, "https://github.com/stritzinger/ro2erl_bridge.git"}}
]}.
```

## Configuration

Configure ro2erl_bridge in your application's sys.config:

```erlang
{ro2erl_bridge, [
    {dispatch_callback, {my_app, handle_message}}
]}.
```

Where:
- `dispatch_callback`: A function that will be called when a message is received from the hub. It can be specified as `{Module, Function}` or `{Module, Function, Args}`.

## Usage

### Sending Messages to Hub

To send a message from the local ROS2 network to the hub:

```erlang
ro2erl_bridge:dispatch(Message).
```

### Receiving Messages from Hub

Messages received from the hub will be passed to the configured `dispatch_callback` function. This function should be defined in your application:

```erlang
-module(my_app).

-export([handle_message/1]).

handle_message(Message) ->
    %% Process the message received from the hub
    ok.
```

## Dependencies

- Erlang/OTP 27 or later
- rosie_rclerl (for ROS2 integration)

## License

Apache License 2.0 