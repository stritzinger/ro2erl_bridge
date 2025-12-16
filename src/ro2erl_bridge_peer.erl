-module(ro2erl_bridge_peer).

-moduledoc """
Peer communication helper for direct-connect mode.
""".

-include_lib("kernel/include/logger.hrl").


%=== EXPORTS ===================================================================

%% API functions
-export([dispatch/4]).


%=== API FUNCTIONS =============================================================

-doc """
Dispatch a message to a peer bridge node.

Sends a cast to the remote `ro2erl_bridge_server` process on `PeerNode`.
""".
-spec dispatch(PeerNode :: node(), Timestamp :: integer(),
               OriginBridgeId :: binary(), Message :: term()) -> ok.
dispatch(PeerNode, Timestamp, OriginBridgeId, Message)
  when is_atom(PeerNode), is_integer(Timestamp), is_binary(OriginBridgeId) ->
    gen_statem:cast({ro2erl_bridge_server, PeerNode},
                    {peer_dispatch, OriginBridgeId, Timestamp, Message}),
    ok.
