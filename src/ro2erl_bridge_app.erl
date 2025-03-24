-module(ro2erl_bridge_app).

-moduledoc """
ro2erl_bridge application callback module
""".

-behaviour(application).


%=== EXPORTS ===================================================================

%% Behaviour application callback functions
-export([start/2, stop/1]).


%=== API FUNCTIONS =============================================================

start(_StartType, _StartArgs) ->
    ro2erl_bridge_sup:start_link().

stop(_State) ->
    ok.
