# RO2ERL Bridge Design Document

## Overview

The `ro2erl_bridge` component is a central element of the Target-X system, designed to bridge ROS2/DDS networks with an Erlang-based distributed system. It operates at robot sites, interfacing with the local ROS2/DDS network and communicating with a central hub. The bridge facilitates secure and reliable connectivity between ROS2 nodes across different sites through the hub component.

## Architecture

### Role in Target-X System

The `ro2erl_bridge` serves as an entry/exit point for ROS2/DDS/RTPS traffic, operating on the local network side of the Target-X system. It works in conjunction with the central hub component (`ro2erl_hub`) to provide:

- Secure message passing between distributed ROS2 networks
- Automatic hub discovery and connection management
- Message filtering and traffic shaping
- Metrics collection and reporting

### Component Structure

The bridge is implemented as an Erlang application with the following key components:

#### Core Components

1. **Bridge Server (`ro2erl_bridge_server`):**
   - Main process handling message dispatch and reception
   - Manages connections to multiple hubs simultaneously
   - Registers with hubs and maintains connection state
   - Processes and forwards messages between local ROS2 network and all attached hubs
   - Collects metrics per topic and applies bandwidth limiting
   - Handles filterable vs non-filterable topic behavior

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
- Extracts topic information from messages
- Processes metrics and applies bandwidth limiting rules
- Forwards messages to the hub, applying filtering for filterable topics
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

## Implementation Details

### State Management
- Uses `gen_statem` behavior for state transitions
- Maintains list of connected hubs
- Handles hub monitoring and reconnection

### Message Processing
- Expects messages to be in rosie client format
- Uses a configurable message processor to extract topic information
- Classifies topics as filterable or non-filterable
- Tracks bandwidth usage per topic using a rolling window algorithm
- Applies bandwidth limits to filterable topics
- Adds timestamps to outgoing messages
- Forwards messages to all attached hubs
- Relies on bridges to understand the rosie client message format

### Metrics and Filtering

The bridge implements a sophisticated metrics and filtering system:

1. **Topic-Based Metrics:**
   - Each topic is tracked independently
   - Metrics are collected for both dispatched and forwarded messages
   - Bandwidth usage (bytes per second) is calculated using a rolling window
   - Message rate (messages per second) is tracked for each topic

2. **Bandwidth Limiting:**
   - Each topic can have an independent bandwidth limit
   - Limits can be set dynamically at runtime
   - When a topic exceeds its bandwidth limit, messages are dropped
   - Limits can be removed by setting to `infinity`

3. **Topic Filtering:**
   - Topics can be marked as filterable or non-filterable
   - Filterable topics are subject to bandwidth limits
   - Non-filterable topics are always forwarded regardless of bandwidth limits
   - This allows critical messages to bypass congestion control

4. **Metrics API:**
   - Provides a metrics API to query current bandwidth and message rates
   - Metrics decay over time using a configurable window (default 5 seconds)
   - Accurate reporting even with time adjustments or NTP updates

### Error Handling
- Graceful handling of hub disconnections
- Automatic reconnection attempts
- Logging of significant state changes
- Detailed logs of message drops due to bandwidth limits

## Message Flow

### Outgoing Messages (Local → Remote)

1. Local ROS2 application generates a message
2. Application calls `ro2erl_bridge:dispatch(Message)`
3. Bridge server processes message to extract topic information
4. Bridge updates dispatch metrics and checks bandwidth limits
5. For filterable topics: if bandwidth limit is exceeded, message is dropped
6. For non-filterable topics: message is always forwarded
7. If forwarded, bridge updates forward metrics
8. Bridge wraps message with metadata (bridge ID, timestamp)
9. Bridge sends wrapped message to all attached hubs
10. Each hub distributes message to its connected bridges
11. Remote bridges dispatch the message to their local networks

### Incoming Messages (Remote → Local)

1. Hub receives message from a remote bridge
2. Hub forwards message to all connected bridges (including sender)
3. Bridge server receives message via `hub_dispatch/1` function
4. Bridge invokes the configured local dispatch callback
5. Local callback processes the message or forwards it to ROS2 nodes

## Configuration

### Required Configuration
- **Dispatch Callback:** Function to handle messages from the hub
  - Specified as `{Module, Function}` or `{Module, Function, Args}`
  - Called when messages are received from the hub
- **Message Processor:** Function to extract topic information from messages
  - Specified as `{Module, Function}` or `{Module, Function, Args}`
  - Must return `{topic, TopicName, Filterable, MsgSize}`
  - Used to process messages before forwarding to the hub
  - Determines if topic is filterable and calculates message size

### Runtime Configuration
- **Bandwidth Limits:** Can be set per topic at runtime
  - `set_topic_bandwidth(TopicName, Limit)` where Limit is bytes/second
  - `set_topic_bandwidth(TopicName, infinity)` removes the limit

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

### Security Through Traffic Management

- Bandwidth limiting provides protection against message flooding
- Topic-based filtering allows for fine-grained control of traffic
- Non-filterable topics ensure critical messages are always delivered

### Future Security Enhancements

- Message validation and authentication
- Enhanced logging and auditing

## Development Status

### Implemented Features
- Basic message dispatch and reception
- Hub discovery and automatic connection
- Simple API for message forwarding
- Message filtering based on topic properties
- Bandwidth limiting and traffic shaping
- Topic-based metrics collection and reporting
- Support for non-filterable (critical) topics

### Planned Features
- Network traffic inspection (Network Mode)
- Advanced analytics and visualization
- Topic-based security policies

## Deployment Considerations

### Supported Platforms
- **Linux Distributions:** Primary platform for standard deployments
- **RTEMS via grisp board:** For embedded deployment scenarios
- **Future RTOS support:** Subject to Erlang/OTP compatibility

### Integration Requirements
- Add `ro2erl_bridge` as a dependency
- Configure a dispatch callback
- Ensure connection to the hub (via grisp.io or custom solution)
- Integration with local ROS2 system via `rosie_rclerl`
- Configure bandwidth limits as appropriate for deployment scenario
