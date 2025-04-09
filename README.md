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

### Start Without TLS Distribution

Start an interactive shell with debug logging and a specific node name:

```bash
rebar3 shell --sname bridge@localhost --setcookie targetx
```

### Start With TLS Distribution

To start a local development shell with support for TLS distribution, you need
first to generate a testing CA and certificate:

```bash
local/setup.sh ../ro2erl_hub
```

Then you can start the shell with:

```bash
ERL_FLAGS='-proto_dist inet_tls -ssl_dist_optfile local/ssl_dist_opts.rel -connect_all false' rebar3 as local shell --sname bridge --setcookie targetx
```

### Connecting to Hub

In the Erlang shell, connect to the hub:

```erlang
1> net_adm:ping(list_to_atom("hub@" ++ lists:nth(2, string:split(atom_to_list(node()), "@")))).
pong
```

### API

Dispatch a message to the hub:

```erlang
2> ro2erl_bridge:dispatch(foobar).
```

## Run tests

```bash
rebar3 ct
```

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

Copyright © 2025 Stritzinger GmbH

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) file for details.
