-module(ro2erl_bridge_sup).

-moduledoc """
ro2erl_bridge top level supervisor.
""".

-behaviour(supervisor).


%=== EXPORTS ===================================================================

%% API functions
-export([start_link/0]).

%% Behaviour supervisor callback functions
-export([init/1]).

-define(SERVER, ?MODULE).


%=== API FUNCTIONS =============================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).


%=== BEHAVIOUR supervisor CALLBACK FUNCTIONS ===================================

init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 10,
        period => 1
    },

    TargetXPgScope = #{
        id => targetx_pg_scope,
        start => {pg, start_link, [targetx_pg_scope]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [pg]
    },

    BridgeServer = #{
        id => ro2erl_bridge_server,
        start => {ro2erl_bridge_server, start_link, [ro2erl_bridge_hub]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [ro2erl_bridge_server]
    },

    HubMonitor = #{
        id => ro2erl_bridge_hub_monitor,
        start => {ro2erl_bridge_hub_monitor, start_link, [
            {ro2erl_bridge_server, ro2erl_bridge_server},
            {targetx_pg_scope, ro2erl_hub_server}
        ]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [ro2erl_bridge_hub_monitor]
    },

    {ok, {SupFlags, [TargetXPgScope, BridgeServer, HubMonitor]}}.
