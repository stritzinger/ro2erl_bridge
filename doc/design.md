# RO2ERL Bridge Design Document

## Overview

The `ro2erl_bridge` component is a central element of the Target-X system, designed to bridge ROS2/DDS networks with an Erlang-based distributed system. It operates at robot sites, interfacing with the local ROS2/DDS network and communicating with a central hub. The bridge facilitates secure and reliable connectivity between ROS2 nodes across different sites through the hub component.

## Architecture

### Role in Target-X System

The `ro2erl_bridge` serves as an entry/exit point for ROS2/DDS/RTPS traffic, operating on the local network side of the Target-X system. It works in conjunction with the central hub component (`ro2erl_hub`) to provide:

- Secure message passing between distributed ROS2 networks
- Automatic hub discovery and connection management
- Message filtering and traffic shaping (future capability)
- Metrics collection and reporting

### Component Structure

The bridge is implemented as an Erlang application with the following key components:

#### Core Components

1. **Bridge Server (`ro2erl_bridge_server`):**
   - Main process handling message dispatch and reception
   - Manages connections to multiple hubs simultaneously
   - Registers with hubs and maintains connection state
   - Processes and forwards messages between local ROS2 network and all attached hubs

2. **Hub Monitor (`ro2erl_bridge_hub_monitor`):**
   - Monitors hub nodes and processes in the Erlang distribution
   - Detects hub availability and notifies the bridge server
   - Handles dynamic connection to available hubs

3. **Bridge API (`ro2erl_bridge`):**
   - Provides public API for dispatching ROS2 messages
   - Exposes simple interface for sending messages to the hub

4. **Bridge Supervisor (`ro2erl_bridge_sup`):**
   - Top-level supervisor ensuring fault tolerance
   - Manages all bridge processes

### Operation Modes

The bridge currently operates in **Dispatch Mode** with the following behavior:

- Receives parsed messages from rosie_rclerl client
- Applies filtering rules (future capability) 
- Forwards messages to the hub
- Receives messages from the hub and dispatches them locally via configured callback

Future development will include **Network Mode** for direct network traffic inspection and generation.

## Communication Protocol

### Bridge-Hub Communication

All communication between the bridge and hub occurs through Erlang distribution, leveraging:

- **Process Groups:** Hub processes register in a process group that bridges monitor
- **Message Format:** All messages include metadata such as:
  - Bridge ID (unique identifier for the bridge instance)
  - Timestamp (when the message was sent)
  - Payload (the actual message content)

### Connection Management

A key architectural decision is the separation of connection management from message handling:

- The bridge does NOT establish or maintain the low-level Erlang distribution connection to the hub
- The bridge implements a higher-level protocol for hub attachment and detachment
- Low-level connection management is delegated to the parent application using `ro2erl_bridge` as a dependency
- For grisp.io framework users, this is handled by the `grisp_connect` library
- This separation enables different deployment scenarios and connection strategies

### Hub Discovery

The bridge utilizes Erlang's process group (`pg`) module to discover hub processes:

1. Bridge starts a hub monitor that watches a specific process group
2. When a hub process joins the group, the bridge is notified
3. The bridge can attach to multiple hub processes
4. If a hub process leaves or crashes, the bridge detaches from that specific hub while maintaining connections to other hubs

## Message Flow

### Outgoing Messages (Local → Remote)

1. Local ROS2 application generates a message
2. Application calls `ro2erl_bridge:dispatch(Message)`
3. Bridge server wraps message with metadata (bridge ID, timestamp)
4. Bridge sends wrapped message to all attached hubs
5. Each hub distributes message to its connected bridges
6. Remote bridges dispatch the message to their local networks

### Incoming Messages (Remote → Local)

1. Hub receives message from a remote bridge
2. Hub forwards message to all connected bridges (including sender)
3. Bridge server receives message via `hub_dispatch/1` function
4. Bridge invokes the configured local dispatch callback
5. Local callback processes the message or forwards it to ROS2 nodes

## Configuration

The bridge is designed to be highly configurable with minimal setup:

### Required Configuration

- **Dispatch Callback:** Function to handle messages from the hub
  - Specified as `{Module, Function}` or `{Module, Function, Args}`
  - Called when messages are received from the hub

### Future Configuration Options

- Metrics collection settings

## Integration with ROS2

The bridge integrates with ROS2 through the `rosie_rclerl` library:

- Messages from ROS2 are received via `rosie_rclerl`
- Bridge forwards these messages to the hub
- Messages from the hub are dispatched locally via the configured callback
- Currently operates at the application level, not directly at the network level

## Security Considerations

### Erlang Distribution Security

The bridge relies on the security of the Erlang distribution for communication:

- When used with grisp.io, all communication is encrypted with TLS
- Certificate-based authentication through the grisp.io framework
- The bridge itself does not implement security measures, delegating to the underlying platform

### Future Security Enhancements

- Message validation and authentication
- Rate limiting to prevent DoS attacks
- Enhanced logging and auditing

## Development Status

The bridge is currently in early development with the following implementation status:

### Implemented Features

- Basic message dispatch and reception
- Hub discovery and automatic connection
- Simple API for message forwarding

### Planned Features

- Message filtering based on rules
- Network traffic inspection (Network Mode)
- Advanced metrics collection and reporting
- Traffic shaping and prioritization

## Deployment Considerations

### Supported Platforms

The bridge is designed to run on various platforms:

- **Linux Distributions:** Primary platform for standard deployments
- **RTEMS via grisp board:** For embedded deployment scenarios
- **Future RTOS support:** Subject to Erlang/OTP compatibility

### Integration Requirements

To integrate the bridge in an application:

- Add `ro2erl_bridge` as a dependency
- Configure a dispatch callback
- Ensure connection to the hub (via grisp.io or custom solution)
- Integration with local ROS2 system via `rosie_rclerl`
