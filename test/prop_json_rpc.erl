-module(prop_json_rpc).
-include_lib("proper/include/proper.hrl").

%%%%%%%%%%%%%%%%%%
%%% Properties %%%
%%%%%%%%%%%%%%%%%%

-export([callback_fn/0, callback_fn/1, callback_fn/2, callback_fn/3,
        callback_fn/4, callback_fn/5, callback_fn/6, callback_fn/7]).

prop_encode_decode_test() ->
    ?FORALL({Method, Params, Id}, {method(), params(), id()},
        begin
            IoData = json_rpc:request(Method, Params, Id),
            DecodedData = json_rpc:decode(IoData),
            R = maps:get(method, DecodedData) =:= Method andalso
            (   Params =:= undefined orelse
                maps:get(params, DecodedData) =:= Params
            ) andalso
            maps:get(id, DecodedData) =:= Id,
            case R of
                false ->
                    io:format("Method: ~p~nParams: ~p~nId: ~p~n", [Method, Params, Id]),
                    io:format("DecodedData: ~p~n", [DecodedData]),
                    false;
                _ ->
                    true
            end
        end).

prop_handle_response_test() ->
    ?FORALL({Method, Params, Id, FnResponse}, {method(), params(), id(), response()},
        begin
            case FnResponse of
                no_register -> ok;
                _ ->
                    erlang:put({?MODULE, resp}, FnResponse),
                    Arity = case Params of
                                undefined -> 0;
                                _ when is_map(Params) -> 1;
                                _ when is_list(Params) -> length(Params)
                            end,
                    json_rpc:register(Method, fun ?MODULE:callback_fn/Arity)
            end,
            DecodedResponse = case json_rpc:handle_request(json_rpc:request(Method, Params, Id)) of
                                 no_response -> no_response;
                                 Response -> json_rpc:decode(Response)
                              end,
            case FnResponse of
                no_register -> ok;
                _ -> json_rpc:unregister(Method)
            end,
            case DecodedResponse of
                #{error := #{code := _Code}} ->
                    %io:format(user, "D: ~p~n", [DecodedResponse]),
                    true;
                #{result := _Res, id := _Id} ->
                    %io:format(user, "Res: ~p -> ~p~n", [Res, Id]),
                    true;
                no_response when FnResponse =:= ok ->
                   true;
                Else ->
                    io:format(user, "error: ~p~n", [Else]),
                    false
            end
        end).

method() ->
    safe_binary().

safe_binary() ->
    ?LET(S, non_empty(safe_string()), begin list_to_binary(S) end).

params() ->
    oneof([
        ?SUCHTHAT(L, list(oneof([integer(), safe_binary(), string()])), begin length(L) =< 6 end),
        non_empty(map(safe_binary(), safe_binary())),
        undefined
    ]).

id() ->
    oneof(
        [null, integer()]
    ).

safe_char() ->
    choose(32, 126).

safe_string() ->
    list(safe_char()).

code() ->
    pos_integer().

success_response() ->
    oneof([ok,  {ok, safe_binary()}]).

error_response() ->
    oneof([
        {error, safe_binary()},
        {error, {code(), safe_binary()}},
        {error, {code(), safe_binary(), safe_binary()}}
    ]).

response() ->
    frequency([{10, success_response()},
                {6, error_response()},
                {1, no_register}]).

callback_fn() ->
    erlang:get({?MODULE, resp}).

callback_fn(_Params) ->
    erlang:get({?MODULE, resp}).

callback_fn(_Params0, _Params1, _Params2, _Params3, _Params4, _Params5, _Params6) ->
    erlang:get({?MODULE, resp}).

callback_fn(_Params0, _Params1, _Params2, _Params3, _Params4, _Params5) ->
    erlang:get({?MODULE, resp}).

callback_fn(_Params0, _Params1, _Params2, _Params3, _Params4) ->
    erlang:get({?MODULE, resp}).

callback_fn(_Params0, _Params1, _Params2, _Params3) ->
    erlang:get({?MODULE, resp}).

callback_fn(_Params0, _Params1, _Params2) ->
    erlang:get({?MODULE, resp}).

callback_fn(_Params0, _Params1) ->
    erlang:get({?MODULE, resp}).




