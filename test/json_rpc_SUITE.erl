-module(json_rpc_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).

all() ->
    [
        rcp_with_positional_parameters_test,
        rcp_with_named_parameters_test,
        notification_test,
        call_non_existent_method_test,
        invalid_json_test,
        invalid_request_object_test,
        call_error_response_test
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(json_rpc),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(json_rpc),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

rcp_with_positional_parameters_test(_Config) ->
    Req = <<"{\"jsonrpc\": \"2.0\", \"method\": \"subtract\", \"params\": [42, 23], \"id\": 1}">>,
    EncodedReq = json_rpc:request("subtract", [42, 23], 1),
    assertEncode(Req, EncodedReq),
    DecodedReqA = json_rpc:decode(Req),
    DecodedReqB = json_rpc:decode(EncodedReq),
    ?assertEqual(#{method => <<"subtract">>, params => [42, 23], id => 1}, DecodedReqB),
    ?assertEqual(DecodedReqA, DecodedReqB),

    Res = <<"{\"jsonrpc\": \"2.0\", \"result\": 19, \"id\": 1}">>,
    DecodedRes = json_rpc:decode(Res),
    ?assertEqual(#{result => 19, id => 1}, DecodedRes),
    EncodedRes = json_rpc:response(19, 1),
    assertEncode(Res, EncodedRes),

    meck_fun(<<"subtract">>, fun(A, B) -> {ok, A - B} end),

    Response = json_rpc:handle_request(Req),
    assertEncode(Res, Response),
    json_rpc:unregister(<<"subtract">>),
    ok.

rcp_with_named_parameters_test(_Config) ->
    Req = <<"{\"jsonrpc\": \"2.0\", \"method\": \"subtract\",",
            "\"params\": {\"subtrahend\": 23, \"minuend\": 42}, \"id\": 3}">>,
    EncodedReq = json_rpc:request("subtract", #{<<"subtrahend">> => 23, <<"minuend">> => 42}, 3),
    assertEncode(Req, EncodedReq),
    DecodedReqA = json_rpc:decode(Req),
    DecodedReqB = json_rpc:decode(EncodedReq),
    ?assertEqual(#{method => <<"subtract">>,
                   params => #{<<"subtrahend">> => 23, <<"minuend">> => 42},
                   id => 3}, DecodedReqB),
    ?assertEqual(DecodedReqA, DecodedReqB),

    Res = <<"{\"jsonrpc\": \"2.0\", \"result\": 19, \"id\": 3}">>,
    DecodedRes = json_rpc:decode(Res),
    ?assertEqual(#{result => 19, id => 3}, DecodedRes),
    EncodedRes = json_rpc:response(19, 3),
    assertEncode(Res, EncodedRes),

    meck_fun(<<"subtract">>, fun(#{<<"subtrahend">> := B, <<"minuend">> := A}) -> {ok, A - B} end),
    Response = json_rpc:handle_request(Req),
    assertEncode(Res, Response),
    json_rpc:unregister(<<"subtract">>),
    ok.

notification_test(_Config) ->
    Req = <<"{\"jsonrpc\": \"2.0\", \"method\": \"update\",\"params\": [1,2,3,4,5]}">>,
    EncodedReq = json_rpc:notification("update", [1, 2, 3, 4, 5]),
    assertEncode(Req, EncodedReq),
    DecodedReqA = json_rpc:decode(Req),
    DecodedReqB = json_rpc:decode(EncodedReq),
    ?assertEqual(#{method => <<"update">>, params => [1, 2, 3, 4, 5]}, DecodedReqB),
    ?assertEqual(DecodedReqA, DecodedReqB),

    _ModuleA = meck_fun(<<"update">>, fun(_, _, _, _, _) -> ok end),
    ?assertEqual(no_response, json_rpc:handle_request(Req)),

    % no params
    ReqNoParams = <<"{\"jsonrpc\": \"2.0\", \"method\": \"update\"}">>,
    EncodedReqNoParams = json_rpc:notification("update"),
    assertEncode(ReqNoParams, EncodedReqNoParams),
    DecodedReqNoParamsA = json_rpc:decode(ReqNoParams),
    DecodedReqNoParamsB = json_rpc:decode(EncodedReqNoParams),
    ?assertEqual(#{method => <<"update">>}, DecodedReqNoParamsB),
    ?assertEqual(DecodedReqNoParamsA, DecodedReqNoParamsB),

    ModuleB = meck_fun(<<"update">>, fun() -> ok end),
    ModuleBBin = atom_to_binary(ModuleB),
    ?assertEqual(no_response, json_rpc:handle_request(ReqNoParams)),

    % error parameter scenario
    assertEncode(<<"{\"jsonrpc\": \"2.0\",",
            "\"error\": {\"code\": -32603, \"message\": ",
            "\"error {badarity,{fun ", ModuleBBin/binary, ":update/0,[1,2,3,4,5]}}\"},
             \"id\": null}">>, json_rpc:handle_request(Req)),

    json_rpc:unregister(<<"update">>),
    ok.

call_error_response_test(_Config) ->
    meck_fun(<<"error">>, fun() -> {error, error_data_here} end),
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"error\", \"params\": [], \"id\": 5}">>,
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32603, \"message\": \"Internal error\",
                    \"data\": \"error_data_here\"},\"id\": 5}">>,
                json_rpc:handle_request(Req1)),

    meck_fun(<<"error">>, fun() -> {error, {123456, <<"error_test">>}} end),
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"error\", \"params\": [], \"id\": 5}">>,
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": 123456, \"message\": \"error_test\"},
                    \"id\": 5}">>,
                json_rpc:handle_request(Req1)),

    meck_fun(<<"error">>, fun() -> {error, {123456, <<"error_test">>, #{foo => bar}}} end),
    Req2 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"error\", \"params\": [], \"id\": 5}">>,
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": 123456, \"message\": \"error_test\",
                    \"data\": {\"foo\": \"bar\"}},
                    \"id\": 5}">>,
        json_rpc:handle_request(Req2)).

call_non_existent_method_test(_Config) ->
    Req = <<"{\"jsonrpc\": \"2.0\", \"method\": \"foobar\", \"id\": \"1\"}">>,
    Res = json_rpc:handle_request(Req),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32601, \"message\": \"Method not found\"},
                    \"id\": \"1\"}">>, Res).

invalid_json_test(_Config) ->
    Req = <<"{\"jsonrpc\": \"2.0\", \"method\": \"foobar, \"params\": \"bar\", \"baz]">>,
    Res = json_rpc:handle_request(Req),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32700, \"message\": \"Parse error\"},
                    \"id\": null}">>, Res).

invalid_request_object_test(_Config) ->
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": 1, \"params\": []}">>,
    Res1 = json_rpc:handle_request(Req1),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res1),
    Req11 = <<"{\"jsonrpc\": \"2.0\", \"method\": 1, \"params\": {\"foo\": 1}}">>,
    Res11 = json_rpc:handle_request(Req11),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res11),
    Req12 = <<"{\"jsonrpc\": \"2.0\", \"method\": 1}">>,
    Res12 = json_rpc:handle_request(Req12),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res12),

    % need to register a fun because parameter check runs after the method/ function checke
    meck_fun(<<"test">>, fun() -> ok end),
    Req2 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"test\", \"params\": \"bar\"}">>,
    Res2 = json_rpc:handle_request(Req2),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res2).

assertEncode(Expect, Current) when is_binary(Current) ->
    ExpectMap = json:decode(Expect),
    CurrentMap = json:decode(Current),
    ?assert(
        ExpectMap =:= CurrentMap,
        {{expected, ExpectMap}, {current, CurrentMap}, {diff, diff(ExpectMap, CurrentMap)}}
    );
assertEncode(Expect, Current) when is_list(Current) ->
    assertEncode(Expect, list_to_binary(Current)).

diff(Expect, Current) ->
    maps:fold(fun(K, V, A) ->
       case maps:is_key(K, A) of
           true ->
               case maps:get(K, A) =:= V of
                   true -> maps:remove(K, A);
                   _ -> A
               end;
           _ -> A
       end
    end, Expect, Current).


meck_fun(Method, Fun) ->
    Pint = erlang:unique_integer([positive]),
    Module = list_to_atom("test_callback_" ++ integer_to_list(Pint)),
    ok = meck:new(Module, [non_strict]),
    FunName = binary_to_atom(Method),
    ok = meck:expect(Module, FunName, Fun),
    {arity, Arity} = erlang:fun_info(Fun, arity),
    ok = json_rpc:register(Method, fun Module:FunName/Arity),
    Module.

