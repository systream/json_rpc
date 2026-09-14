%%%-------------------------------------------------------------------
%%% @author Peter Tihanyi
%%% @copyright (C) 2026, systream
%%% @doc
%%% JSON-RPC 2.0 Specification Implementation
%%% @end
%%%-------------------------------------------------------------------
-module(json_rpc).

-define(VERSION, <<"2.0">>).

%% Standard JSON-RPC 2.0 Error Codes
-define(PARSE_ERROR, -32700).
-define(INVALID_REQUEST, -32600).
-define(METHOD_NOT_FOUND, -32601).
-define(INVALID_PARAMS, -32602).
-define(INTERNAL_ERROR, -32603).

-type json_rpc() :: #{}.
-type method() :: binary() | string().
-type id() :: integer() | binary() | float() | null.
-type params() :: list() | map() | undefined.

-export_type([json_rpc/0, method/0, id/0, params/0]).

%% API
-export([
  decode/1,
  notification/1, notification/2,
  request/3,
  response/2,
  error_response/3, error_response/4,
  handle_request/1,
  register/2,
  unregister/1
]).

-spec register(method(), function()) -> ok.
register(Method, Fun) ->
  persistent_term:put({?MODULE, to_binary(Method)}, Fun).

-spec unregister(method()) -> ok.
unregister(Method) ->
  _ = persistent_term:erase({?MODULE, to_binary(Method)}),
  ok.

-spec handle_request(iodata() | binary()) -> iodata() | no_response.
handle_request(Request) ->
  try
    case json:decode(Request) of
      [] ->
        error_response(?INVALID_REQUEST, <<"Invalid Request">>, null);
      Single when is_map(Single) ->
        execute_single(Single);
      Batch when is_list(Batch) ->
        execute_batch(Batch);
      _Other ->
        error_response(?INVALID_REQUEST, <<"Invalid Request">>, null)
    end
  catch
    error:{invalid_byte, _}:_Stack ->
      error_response(?PARSE_ERROR, <<"Parse error">>, null);
    error:unexpected_end:_Stack ->
      error_response(?PARSE_ERROR, <<"Parse error">>, null);
    error:{unexpected_sequence, _}:_Stack ->
      error_response(?PARSE_ERROR, <<"Parse error">>, null);
    _Type:_Error:_Stack ->
      error_response(?PARSE_ERROR, <<"Parse error">>, null)
  end.

-spec decode(binary() | iodata() | map() | list()) ->
  #{method := binary(), params => list() | map(), id => id()} |
  #{result => term(), id => id()} |
  #{error => #{code := integer(), message => binary(), data => term()}, id => id()} |
  [map()].
decode(#{<<"jsonrpc">> := ?VERSION, <<"method">> := Method} = Data) when is_binary(Method) ->
  Result0 = #{method => Method},
  Result1 = maybe_add(params, maps:get(<<"params">>, Data, undefined), Result0),
  maybe_add(id, maps:get(<<"id">>, Data, undefined), Result1);
decode(#{<<"jsonrpc">> := ?VERSION, <<"result">> := Result} = Data) ->
  Response0 = #{result => Result},
  maybe_add(id, maps:get(<<"id">>, Data, undefined), Response0);
decode(#{<<"jsonrpc">> := ?VERSION, <<"error">> := Error} = Data) when is_map(Error) ->
  Error0 = #{code => maps:get(<<"code">>, Error)},
  Error1 = maybe_add(message, maps:get(<<"message">>, Error, undefined), Error0),
  Error2 = maybe_add(data, maps:get(<<"data">>, Error, undefined), Error1),
  Response0 = #{error => Error2},
  maybe_add(id, maps:get(<<"id">>, Data, undefined), Response0);
decode([First | _] = Data) when is_map(First) ->
  lists:map(fun decode/1, Data);
decode(Data) when is_binary(Data) ->
  case json:decode(Data) of
    DecodedData when is_list(DecodedData) ->
      lists:map(fun decode/1, DecodedData);
    DecodedData ->
      decode(DecodedData)
  end;
decode(Data) when is_list(Data) ->
  decode(iolist_to_binary(Data));
decode(_Other) ->
  list_to_binary(error_response(?PARSE_ERROR, <<"Parse error">>, null)).

-spec notification(method()) -> iodata().
notification(Method) ->
  request(Method, undefined, undefined).

-spec notification(method(), params()) -> iodata().
notification(Method, Params) ->
  request(Method, Params, undefined).

-spec request(method(), params(), id() | undefined) -> iodata().
request(Method, Params, Id) ->
  Command0 = #{jsonrpc => ?VERSION,
               method => to_binary(Method)},
  Command1 = maybe_add(params, Params, Command0),
  Command2 = maybe_add(id, Id, Command1),
  json:encode(Command2).

-spec response(term(), id()) -> iodata().
response(Result, Id) ->
  Response = #{jsonrpc => ?VERSION,
               result => Result,
               id => Id},
  json:encode(Response).

-spec error_response(integer(), binary() | string(), id()) -> iodata().
error_response(Code, Message, Id) ->
  error_response(Code, Message, Id, undefined).

-spec error_response(integer(), binary() | string(), id(), term() | undefined) -> iodata().
error_response(Code, Message, Id, ErrorData) ->
  Response = #{jsonrpc => ?VERSION,
               error => maybe_add(data, ErrorData, #{code => Code, message => to_binary(Message)}),
               id => Id},
  json:encode(Response).

-spec maybe_add(atom(), term() | undefined, map()) -> map().
maybe_add(_Key, undefined, Acc) ->
  Acc;
maybe_add(Key, Value, Acc) ->
  Acc#{Key => Value}.

to_binary(Val) when is_binary(Val) ->
  Val;
to_binary(Val) when is_list(Val) ->
  unicode:characters_to_binary(Val).

execute_batch(Batch) ->
  Spawned = lists:map(fun spawn_execute/1, Batch),
  Results = gather_results(Spawned),
  case [R || R <- Results, R =/= no_response] of
    [] ->
      no_response;
    Responses ->
      ["[", lists:join(<<",">>, Responses), "]"]
  end.

spawn_execute(Request) ->
  Parent = self(),
  Ref = make_ref(),
  {Pid, MonRef} = spawn_monitor(fun() ->
    Res = execute_single(Request),
    Parent ! {Ref, Res}
  end),
  {Pid, MonRef, Ref}.

gather_results(Spawned) ->
  lists:map(fun({Pid, MonRef, Ref}) ->
    receive
      {Ref, Result} ->
        erlang:demonitor(MonRef, [flush]),
        Result;
      {'DOWN', MonRef, process, Pid, Reason} ->
        error_response(?INTERNAL_ERROR, <<"Internal error">>, null, Reason)
    end
  end, Spawned).

execute_single(#{<<"jsonrpc">> := ?VERSION, <<"method">> := Method} = Req)
    when is_binary(Method) ->
  Params = maps:get(<<"params">>, Req, undefined),
  case is_valid_params(Params) of
    false ->
      error_response(?INVALID_REQUEST, <<"Invalid Request">>, null);
    true when is_map_key(<<"id">>, Req) ->
      Id = maps:get(<<"id">>, Req),
      case is_valid_id(Id) of
        true ->
          dispatch_call(Method, Params, Id);
        false ->
          error_response(?INVALID_REQUEST, <<"Invalid Request">>, null)
      end;
    true ->
      dispatch_notification(Method, Params)
  end;
execute_single(_) ->
  error_response(?INVALID_REQUEST, <<"Invalid Request">>, null).

is_valid_params(undefined) -> true;
is_valid_params(Params) when is_list(Params) -> true;
is_valid_params(Params) when is_map(Params) -> true;
is_valid_params(_) -> false.

is_valid_id(null) -> true;
is_valid_id(Id) when is_integer(Id) -> true;
is_valid_id(Id) when is_binary(Id) -> true;
is_valid_id(_) -> false.

dispatch_notification(Method, Params) ->
  case persistent_term:get({?MODULE, Method}, undefined) of
    undefined ->
      error_response(?METHOD_NOT_FOUND, <<"Method not found">>, null);
    Function ->
      % notification should be return with ok
      ok = execute_function(Function, Params),
      no_response
  end.

dispatch_call(Method, Params, Id) ->
  case persistent_term:get({?MODULE, Method}, undefined) of
    undefined ->
      error_response(?METHOD_NOT_FOUND, <<"Method not found">>, Id);
    Function ->
      try execute_function(Function, Params) of
        {ok, Result} ->
          response(Result, Id);
        ok -> % should we support this? I mean call should return with a reply
          no_response;
        {error, {Code, Message}} ->
          error_response(Code, Message, Id);
        {error, {Code, Message, Data}} ->
          error_response(Code, Message, Id, Data);
        {error, Data} ->
          error_response(?INTERNAL_ERROR, <<"Internal error">>, Id, Data);
        Else ->
          error_response(?INTERNAL_ERROR, <<"Internal error">>, Id,
                         {not_proper_response, Else})
      catch
        error:{badarity, _}:_Stack ->
          error_response(?INVALID_PARAMS, <<"Invalid params">>, Id);
        Type:Error:_Stack ->
          error_response(?INTERNAL_ERROR, <<"Internal error">>, Id,
                         io_lib:bformat("~p ~p", [Type, Error]))
      end
  end.

execute_function(Function, undefined) ->
  erlang:apply(Function, []);
execute_function(Function, Params) when is_list(Params) ->
  erlang:apply(Function, Params);
execute_function(Function, Params) when is_map(Params) ->
  erlang:apply(Function, [Params]).