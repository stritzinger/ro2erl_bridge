# RO2ERL Bridge

A bridge component for the Target-X system that connects local ROS2/DDS networks to the central hub.

## Overview

ro2erl_bridge is a component in the Target-X system that:
1. Connects to the central hub
2. Forwards messages from the local ROS2/DDS network to the hub
3. Receives messages from the hub and forwards them to the local network

For detailed design information, see:
- [Bridge Design Documentation](doc/design.md)
- [RO2ERL Documentation](https://github.com/stritzinger/ro2erl_doc)

## Features

- Hub discovery and automatic registration
- Message forwarding to/from the hub
- Message filtering (future)
- Customizable local dispatch callback

## Requirements

- Erlang/OTP 27 or later
- rebar3

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

## Development

For local development and testing:

```bash
# Start an interactive shell with debug logging and a specific node name
rebar3 shell --sname bridge@localhost --setcookie targetx

% In the Erlang shell, connect to the hub
1> net_adm:ping('hub@localhost').
pong

% Dispatch a message to the hub
2> ro2erl_bridge:dispatch(foobar).

# Run tests
rebar3 ct
```

The bridge node will be started with the short name `bridge` and the cookie `targetx`. The `net_adm:ping/1` call establishes the connection between the nodes, and then the bridge will attach automatically.

## Production Deployment

For production deployment on grisp.io:

```bash
# Build the release with production dependencies
rebar3 as prod release

# Build the Docker image for deployment
rebar3 as prod docker

# Push the image to your registry
docker push local/ro2erl_bridge:0.1.0 your-registry/ro2erl_bridge:0.1.0
```

The production build includes the braidnode dependency which is required for deployment on grisp.io. This dependency is not included in the development environment to simplify local testing.

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
