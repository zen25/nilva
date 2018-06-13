-module(prop_nilva_helper).
-include_lib("proper/include/proper.hrl").

prop_demo() -> % auto-exported by Proper
    ?FORALL(_N, integer(), true). % always fail
