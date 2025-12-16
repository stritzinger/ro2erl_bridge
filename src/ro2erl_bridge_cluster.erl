-module(ro2erl_bridge_cluster).

-moduledoc """
Cluster connector abstraction for direct-connect mode.

Attempts to use `grisp_connect_cluster:join/2` when available, otherwise falls
back to `net_kernel:connect_node/1`.
""".

-include_lib("kernel/include/logger.hrl").


%=== EXPORTS ===================================================================

%% API functions
-export([is_available/0, ensure_peer/2]).


%=== API FUNCTIONS =============================================================

-spec is_available() -> boolean().
is_available() ->
    code:ensure_loaded(grisp_connect_cluster) =:= {module, grisp_connect_cluster}
        andalso erlang:function_exported(grisp_connect_cluster, join, 2).

-spec ensure_peer(node(), map()) -> ok | {error, term()}.
ensure_peer(PeerNode, Opts) when is_atom(PeerNode), is_map(Opts) ->
    case PeerNode =:= node() of
        true -> ok;
        false -> ensure_remote_peer(PeerNode, Opts)
    end.

ensure_remote_peer(PeerNode, Opts) ->
    case is_available() andalso application_loaded(grisp_connect) of
        true ->
            call_grisp_join(PeerNode, Opts);
        false ->
            connect_fallback(PeerNode)
    end.


%=== INTERNAL FUNCTIONS ========================================================

-spec application_loaded(atom()) -> boolean().
application_loaded(App) ->
    lists:keymember(App, 1, application:which_applications()).

-spec call_grisp_join(node(), map()) -> ok | {error, term()}.
call_grisp_join(PeerNode, Opts) ->
    try grisp_connect_cluster:join(PeerNode, Opts) of
        true -> ok;
        false -> {error, not_connected};
        error -> {error, join_failed}
    catch
        _:Reason ->
            ?LOG_WARNING("grisp_connect_cluster:join failed for ~p: ~p",
                         [PeerNode, Reason]),
            connect_fallback(PeerNode)
    end.

-spec connect_fallback(node()) -> ok | {error, term()}.
connect_fallback(PeerNode) ->
    case net_kernel:connect_node(PeerNode) of
        true -> ok;
        _ -> {error, connect_failed}
    end.
