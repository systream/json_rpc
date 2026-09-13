# json_rpc

Erlang implementation of the [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification) 

## Usage

### Server: Register Handlers & Handle Requests

Register functions to handle methods. Handlers are dispatched based on parameter type:
- **List params:** Applied with arity equal to list length (`erlang:apply(Fun, Params)`).
- **Map params:** Passed as a single map argument (`Fun(ParamsMap)`).
- **No params / undefined:** Called with 0 arity (`Fun()`).

```erlang
%% Register positional parameter handler
json_rpc:register(<<"subtract">>, fun(A, B) -> {ok, A - B} end).

%% Register named parameter handler
json_rpc:register(<<"subtract_named">>, fun(#{<<"subtrahend">> := B, <<"minuend">> := A}) ->
    {ok, A - B}
end).

%% Register notification / parameterless handler
json_rpc:register(<<"ping">>, fun() -> ok end).

%% Handle an incoming JSON-RPC request (binary or iodata)
Response = json_rpc:handle_request(<<"{\"jsonrpc\":\"2.0\",\"method\":\"subtract\",\"params\":[42,23],\"id\":1}">>).
%% => <<"{\"jsonrpc\":\"2.0\",\"result\":19,\"id\":1}">>

%% Unregister when no longer needed
json_rpc:unregister(<<"subtract">>).
```

#### Handler Return Values

| Return Value | Response |
|---|---|
| `{ok, Result}` | Success response: `{"jsonrpc":"2.0","result":Result,"id":Id}` |
| `ok` | `no_response` (used for notifications) |
| `{error, {Code, Message}}` | Custom error response with code and message |
| `{error, {Code, Message, Data}}` | Custom error response with code, message, and error data |
| `{error, Data}` | Internal error (`-32603`) containing error data |

---

### Client: Create Requests & Notifications

```erlang
%% Request with positional params
Req1 = json_rpc:request(<<"subtract">>, [42, 23], 1).

%% Request with named params
Req2 = json_rpc:request(<<"subtract">>, #{<<"subtrahend">> => 23, <<"minuend">> => 42}, 2).

%% Notification (no id, no reply expected)
Note1 = json_rpc:notification(<<"ping">>).
Note2 = json_rpc:notification(<<"update">>, [1, 2, 3, 4, 5]).
```

---

### Decoding Messages

Decode raw JSON-RPC requests, responses, or error payloads into maps:

```erlang
Decoded = json_rpc:decode(<<"{\"jsonrpc\":\"2.0\",\"method\":\"subtract\",\"params\":[42,23],\"id\":1}">>).
%% => #{method => <<"subtract">>, params => [42, 23], id => 1}

DecodedRes = json_rpc:decode(<<"{\"jsonrpc\":\"2.0\",\"result\":19,\"id\":1}">>).
%% => #{result => 19, id => 1}
```

---

### Manual Responses

```erlang
%% Success response
Res = json_rpc:response(19, 1).

%% Error response
Err = json_rpc:error_response(-32601, <<"Method not found">>, 1).
ErrWithData = json_rpc:error_response(-32602, <<"Invalid params">>, 1, #{<<"detail">> => <<"missing argument">>}).
```

---

## Build & Test

```bash
rebar3 test
```
