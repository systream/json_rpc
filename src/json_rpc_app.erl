%%%-------------------------------------------------------------------
%% @doc json_rpc public API
%% @end
%%%-------------------------------------------------------------------

-module(json_rpc_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    json_rpc_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
