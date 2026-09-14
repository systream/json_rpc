-module(json_rpc_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).

all() ->
    [
        rpc_with_positional_parameters_test,
        rpc_with_named_parameters_test,
        notification_test,
        notification_error_scenarios_test,
        request_id_preserved_on_crash_test,
        call_non_existent_method_test,
        invalid_json_test,
        invalid_request_object_test,
        invalid_json_rpc_objects_test,
        call_error_response_test,
        batch_test,
        batch_empty_test,
        batch_notification_test,
        batch_with_trailing_notification_test,
        batch_with_various_invalid_items_test,
        batch_all_notifications_test,
        batch_error_test,
        mailbox_cleanliness_test,
        register_unregister_string_method_test,
        string_message_in_error_response_test,
        decode_api_test
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

rpc_with_positional_parameters_test(_Config) ->
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

rpc_with_named_parameters_test(_Config) ->
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

    _ModuleB = meck_fun(<<"update">>, fun() -> ok end),
    ?assertEqual(no_response, json_rpc:handle_request(ReqNoParams)),

    % error parameter scenario for notification returns no_response per spec Section 4.1
    ?assertEqual(no_response, json_rpc:handle_request(Req)),

    % request with ID calling with bad params returns Invalid params error (-32602) with ID
    ReqWithId = <<"{\"jsonrpc\": \"2.0\", \"method\": \"update\", \"params\": [1,2,3,4,5], \"id\": 99}">>,
    ResWithId = json_rpc:handle_request(ReqWithId),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",",
            "\"error\": {\"code\": -32602, \"message\": \"Invalid params\"},",
            "\"id\": 99}">>, ResWithId),

    json_rpc:unregister(<<"update">>),
    ok.

notification_error_scenarios_test(_Config) ->
    % 1. Method not found on notification
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"non_existent_notify\"}">>,
    ?assertEqual(no_response, json_rpc:handle_request(Req1)),

    % 2. Handler crash on notification
    meck_fun(<<"crash_notify">>, fun() -> error(boom) end),
    Req2 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"crash_notify\"}">>,
    ?assertEqual(no_response, json_rpc:handle_request(Req2)),

    % 3. Handler returns {error, ...} on notification
    meck_fun(<<"err_notify">>, fun() -> {error, {123, <<"fail">>}} end),
    Req3 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"err_notify\"}">>,
    ?assertEqual(no_response, json_rpc:handle_request(Req3)),

    % 4. Handler returns {ok, Result} on notification
    meck_fun(<<"ok_notify">>, fun() -> {ok, <<"ignored_result">>} end),
    Req4 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"ok_notify\"}">>,
    ?assertEqual(no_response, json_rpc:handle_request(Req4)),

    json_rpc:unregister(<<"crash_notify">>),
    json_rpc:unregister(<<"err_notify">>),
    json_rpc:unregister(<<"ok_notify">>),
    ok.

request_id_preserved_on_crash_test(_Config) ->
    meck_fun(<<"crash_call">>, fun() -> error(boom) end),

    % Integer ID preserved
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"crash_call\", \"id\": 42}">>,
    Res1 = json_rpc:handle_request(Req1),
    Decoded1 = json:decode(iolist_to_binary(Res1)),
    ?assertEqual(42, maps:get(<<"id">>, Decoded1)),
    Err1 = maps:get(<<"error">>, Decoded1),
    ?assertEqual(-32603, maps:get(<<"code">>, Err1)),
    ?assertEqual(<<"Internal error">>, maps:get(<<"message">>, Err1)),

    % String ID preserved
    Req2 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"crash_call\", \"id\": \"req_str_99\"}">>,
    Res2 = json_rpc:handle_request(Req2),
    Decoded2 = json:decode(iolist_to_binary(Res2)),
    ?assertEqual(<<"req_str_99">>, maps:get(<<"id">>, Decoded2)),
    Err2 = maps:get(<<"error">>, Decoded2),
    ?assertEqual(-32603, maps:get(<<"code">>, Err2)),

    % Throw preserved
    meck_fun(<<"throw_call">>, fun() -> throw(oops) end),
    Req3 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"throw_call\", \"id\": 777}">>,
    Res3 = json_rpc:handle_request(Req3),
    Decoded3 = json:decode(iolist_to_binary(Res3)),
    ?assertEqual(777, maps:get(<<"id">>, Decoded3)),

    json_rpc:unregister(<<"crash_call">>),
    json_rpc:unregister(<<"throw_call">>),
    ok.

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

    meck_fun(<<"test">>, fun() -> ok end),
    Req2 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"test\", \"params\": \"bar\"}">>,
    Res2 = json_rpc:handle_request(Req2),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res2),
    json_rpc:unregister(<<"test">>).

invalid_json_rpc_objects_test(_Config) ->
    % Primitive number
    Res1 = json_rpc:handle_request(<<"123">>),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res1),

    % Primitive string
    Res2 = json_rpc:handle_request(<<"\"some_string\"">>),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res2),

    % Map without jsonrpc version
    Res3 = json_rpc:handle_request(<<"{\"method\": \"foo\", \"id\": 1}">>),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res3),

    % Map with wrong jsonrpc version
    Res4 = json_rpc:handle_request(<<"{\"jsonrpc\": \"1.0\", \"method\": \"foo\", \"id\": 1}">>),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res4),

    % Map without method
    Res5 = json_rpc:handle_request(<<"{\"jsonrpc\": \"2.0\", \"id\": 1}">>),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res5),

    % Invalid ID type (array)
    Res6 = json_rpc:handle_request(<<"{\"jsonrpc\": \"2.0\", \"method\": \"foo\", \"id\": [1,2]}">>),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res6),

    % Arbitrary JSON map
    Res7 = json_rpc:handle_request(<<"{\"foo\": \"bar\"}">>),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, Res7),
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
        json_rpc:handle_request(Req2)),
    json_rpc:unregister(<<"error">>).

batch_test(_Config) ->
    meck_fun(<<"subtract">>, fun(A, B) -> {ok, A - B} end),
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"subtract\", \"params\": [1, 1], \"id\": 1}">>,
    Req2 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"subtract\", \"params\": [2, 2], \"id\": 2}">>,
    BatchReq = <<"[", Req1/binary, ",", Req2/binary, "]">>,
    BatchRes = json_rpc:handle_request(BatchReq),
    assertEncode(<<"[{\"jsonrpc\": \"2.0\", \"result\": 0, \"id\": 1},
                     {\"jsonrpc\": \"2.0\", \"result\": 0, \"id\": 2}]">>, BatchRes),
    json_rpc:unregister(<<"subtract">>).

batch_empty_test(_Config) ->
    BatchReq = <<"[]">>,
    BatchRes = json_rpc:handle_request(BatchReq),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                    \"id\": null}">>, BatchRes).

batch_notification_test(_Config) ->
    meck_fun(<<"subtract">>, fun(A, B) -> {ok, A - B} end),
    meck_fun(<<"notify">>, fun() -> ok end),
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"subtract\", \"params\": [1, 1], \"id\": 1}">>,
    Req2 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"notify\"}">>,
    Req3 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"subtract\", \"params\": [2, 1], \"id\": 2}">>,
    BatchReq = <<"[", Req1/binary, ",", Req2/binary, ",", Req3/binary, "]">>,
    BatchRes = json_rpc:handle_request(BatchReq),
    assertEncode(<<"[{\"jsonrpc\": \"2.0\", \"result\": 0, \"id\": 1},
                     {\"jsonrpc\": \"2.0\", \"result\": 1, \"id\": 2}]">>, BatchRes),

    BatchReq1 = <<"[", Req2/binary, ",", Req2/binary, "]">>,
    ?assertEqual(no_response, json_rpc:handle_request(BatchReq1)),

    json_rpc:unregister(<<"subtract">>),
    json_rpc:unregister(<<"notify">>).

batch_with_trailing_notification_test(_Config) ->
    % Tests that batch where the notification is the LAST element produces valid JSON array
    meck_fun(<<"subtract">>, fun(A, B) -> {ok, A - B} end),
    meck_fun(<<"notify">>, fun() -> ok end),
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"subtract\", \"params\": [10, 3], \"id\": 1}">>,
    Req2 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"notify\"}">>,
    BatchReq = <<"[", Req1/binary, ",", Req2/binary, "]">>,
    BatchRes = json_rpc:handle_request(BatchReq),
    assertEncode(<<"[{\"jsonrpc\": \"2.0\", \"result\": 7, \"id\": 1}]">>, BatchRes),

    json_rpc:unregister(<<"subtract">>),
    json_rpc:unregister(<<"notify">>).

batch_with_various_invalid_items_test(_Config) ->
    meck_fun(<<"add">>, fun(A, B) -> {ok, A + B} end),
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"add\", \"params\": [3, 4], \"id\": 10}">>,
    BatchReq = <<"[123, {\"foo\": \"bar\"}, {\"jsonrpc\": \"1.0\", \"method\": \"add\", \"id\": 1}, ", Req1/binary, "]">>,
    BatchRes = json_rpc:handle_request(BatchReq),
    assertEncode(<<"[{\"jsonrpc\": \"2.0\", \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"}, \"id\": null},
                     {\"jsonrpc\": \"2.0\", \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"}, \"id\": null},
                     {\"jsonrpc\": \"2.0\", \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"}, \"id\": null},
                     {\"jsonrpc\": \"2.0\", \"result\": 7, \"id\": 10}]">>, BatchRes),
    json_rpc:unregister(<<"add">>).

batch_all_notifications_test(_Config) ->
    meck_fun(<<"n1">>, fun() -> ok end),
    meck_fun(<<"n2">>, fun(_) -> ok end),
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"n1\"}">>,
    Req2 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"n2\", \"params\": [42]}">>,
    BatchReq = <<"[", Req1/binary, ",", Req2/binary, "]">>,
    ?assertEqual(no_response, json_rpc:handle_request(BatchReq)),
    json_rpc:unregister(<<"n1">>),
    json_rpc:unregister(<<"n2">>).

batch_error_test(_Config) ->
    meck_fun(<<"subtract">>, fun(A, B) -> {ok, A - B} end),
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"subtract\", \"params\": [1, 1], \"id\": 1}">>,
    BatchReq = <<"[", Req1/binary, ", 123]">>,
    BatchRes = json_rpc:handle_request(BatchReq),
    assertEncode(<<"[{\"jsonrpc\": \"2.0\", \"result\": 0, \"id\": 1},
                     {\"jsonrpc\": \"2.0\",
                      \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"},
                      \"id\": null}]">>, BatchRes),

    json_rpc:unregister(<<"subtract">>).

mailbox_cleanliness_test(_Config) ->
    meck_fun(<<"mailbox_op">>, fun(X) -> {ok, X * 2} end),
    Req1 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"mailbox_op\", \"params\": [2], \"id\": 1}">>,
    Req2 = <<"{\"jsonrpc\": \"2.0\", \"method\": \"mailbox_op\", \"params\": [4], \"id\": 2}">>,
    BatchReq = <<"[", Req1/binary, ",", Req2/binary, "]">>,
    _Res = json_rpc:handle_request(BatchReq),
    {messages, Messages} = process_info(self(), messages),
    ?assertEqual([], Messages),
    json_rpc:unregister(<<"mailbox_op">>).

register_unregister_string_method_test(_Config) ->
    json_rpc:register("string_method", fun(A, B) -> {ok, A * B} end),
    Req = <<"{\"jsonrpc\": \"2.0\", \"method\": \"string_method\", \"params\": [3, 5], \"id\": 1}">>,
    Res = json_rpc:handle_request(Req),
    assertEncode(<<"{\"jsonrpc\": \"2.0\", \"result\": 15, \"id\": 1}">>, Res),

    ok = json_rpc:unregister("string_method"),
    ResAfter = json_rpc:handle_request(Req),
    assertEncode(<<"{\"jsonrpc\": \"2.0\",
                    \"error\": {\"code\": -32601, \"message\": \"Method not found\"},
                    \"id\": 1}">>, ResAfter).

string_message_in_error_response_test(_Config) ->
    % Charlist string message coerced to JSON string
    ErrRes1 = json_rpc:error_response(-32601, "Method not found", 1),
    Decoded1 = json:decode(list_to_binary(ErrRes1)),
    ErrorObj1 = maps:get(<<"error">>, Decoded1),
    ?assertEqual(<<"Method not found">>, maps:get(<<"message">>, ErrorObj1)),

    % Handler returning {error, {Code, CharlistMessage}}
    meck_fun(<<"str_err_method">>, fun() -> {error, {1234, "Custom error string"}} end),
    Req = <<"{\"jsonrpc\": \"2.0\", \"method\": \"str_err_method\", \"id\": 7}">>,
    Res = json_rpc:handle_request(Req),
    Decoded2 = json:decode(iolist_to_binary(Res)),
    ErrorObj2 = maps:get(<<"error">>, Decoded2),
    ?assertEqual(1234, maps:get(<<"code">>, ErrorObj2)),
    ?assertEqual(<<"Custom error string">>, maps:get(<<"message">>, ErrorObj2)),
    json_rpc:unregister(<<"str_err_method">>).

decode_api_test(_Config) ->
    % 1. Decode Request
    ReqBin = <<"{\"jsonrpc\": \"2.0\", \"method\": \"sub\", \"params\": [1, 2], \"id\": 1}">>,
    ?assertEqual(#{method => <<"sub">>, params => [1, 2], id => 1}, json_rpc:decode(ReqBin)),

    % 2. Decode Response
    ResBin = <<"{\"jsonrpc\": \"2.0\", \"result\": 42, \"id\": 1}">>,
    ?assertEqual(#{result => 42, id => 1}, json_rpc:decode(ResBin)),

    % 3. Decode Error Response
    ErrBin = <<"{\"jsonrpc\": \"2.0\", \"error\": {\"code\": -32600, \"message\": \"Invalid Request\"}, \"id\": null}">>,
    ?assertEqual(#{error => #{code => -32600, message => <<"Invalid Request">>}, id => null}, json_rpc:decode(ErrBin)),

    % 4. Decode Batch
    BatchBin = <<"[", ReqBin/binary, ",", ResBin/binary, "]">>,
    DecodedBatch = json_rpc:decode(BatchBin),
    ?assertEqual([
        #{method => <<"sub">>, params => [1, 2], id => 1},
        #{result => 42, id => 1}
    ], DecodedBatch),

    % 5. Decode list of maps
    MapList = [
        #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"test">>, <<"id">> => 2}
    ],
    ?assertEqual([#{method => <<"test">>, id => 2}], json_rpc:decode(MapList)).

assertEncode(Expect, Current) when is_binary(Current) ->
    ExpectMap = json:decode(Expect),
    CurrentMap = json:decode(Current),
    ExpectMapSorted = assert_sort(ExpectMap),
    CurrentMapSorted = assert_sort(CurrentMap),
    ?assert(
        ExpectMapSorted =:= CurrentMapSorted,
        {{expected, ExpectMapSorted}, {current, CurrentMapSorted}, {diff, diff(ExpectMapSorted, CurrentMapSorted)}}
    );
assertEncode(Expect, Current) when is_list(Current) ->
    assertEncode(Expect, list_to_binary(Current)).

diff(Expect, Current) when is_map(Expect) andalso is_map(Current) ->
    maps:fold(fun(K, V, A) ->
       case maps:is_key(K, A) of
           true ->
               case maps:get(K, A) =:= V of
                   true -> maps:remove(K, A);
                   _ -> A
               end;
           _ -> A
       end
    end, Expect, Current);
diff(Expect, Current) when is_list(Expect) andalso is_list(Current) ->
    lists:map(fun ({A, B}) -> diff(A, B) end, lists:zip(Expect, Current)).

assert_sort(Result) when is_list(Result) ->
    lists:sort(fun assert_sort/2, Result);
assert_sort(Result) ->
    Result.

assert_sort(#{<<"id">> := IdA}, #{<<"id">> := IdB}) ->
    IdA > IdB;
assert_sort(_, _) ->
    true.

meck_fun(Method, Fun) ->
    Pint = erlang:unique_integer([positive]),
    Module = list_to_atom("test_callback_" ++ integer_to_list(Pint)),
    ok = meck:new(Module, [non_strict]),
    FunName = binary_to_atom(Method),
    ok = meck:expect(Module, FunName, Fun),
    {arity, Arity} = erlang:fun_info(Fun, arity),
    ok = json_rpc:register(Method, fun Module:FunName/Arity),
    Module.
