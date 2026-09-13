%%%-------------------------------------------------------------------
%%% @author Peter Tihanyi
%%% @copyright (C) 2026, systream
%%% @doc
%%%
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

-type json_rcp() :: #{}.
-type method() :: binary().
-type id() :: integer() | binary() | null.
-type params() :: list() | map() | undefined.

-export_type([json_rcp/0, method/0, id/0, params/0]).

%% API
-export([
  decode/1,
  notification/1, notification/2,
  request/3,
  response/2, error_response/3,
  handle_request/1,
  register/2,
  unregister/1]).


-spec register(method(), function()) -> ok.
register(Method, Fun) ->
  persistent_term:put({?MODULE, Method}, Fun).

-spec unregister(method()) -> ok.
unregister(Method) ->
  persistent_term:erase({?MODULE, Method}),
  ok.

-spec handle_request(iodata() | binary()) -> iodata() | no_response.
handle_request(Request) ->
  try
    execute(decode(Request))
  catch
    error:{invalid_byte, _}:_  ->
      error_response(?PARSE_ERROR, <<"Parse error">>, null);
    error:unexpected_end:_  ->
      error_response(?PARSE_ERROR, <<"Parse error">>, null, unexpected_end);
    error:{unexpected_sequence, _}:_  ->
      error_response(?PARSE_ERROR, <<"Parse error">>, null, unexpected_sequence);
    Type:Error:_St ->
      error_response(?INTERNAL_ERROR, io_lib:bformat("~p ~p ~p", [Type, Error, _St]), null)
  end.

-spec decode(binary() | json_rcp() | iodata()) ->
  #{method := binary(), params => list() | map(), id => id()} |
  #{response := term(), id => id(), error => #{code := integer(), message => binary(), data => term()}}.
decode(#{<<"jsonrpc">> := ?VERSION, <<"method">> := Method} = Data) ->
  Result0 = #{method => Method},
  Result1 = maybe_add(params, maps:get(<<"params">>, Data, undefined), Result0),
  maybe_add(id, maps:get(<<"id">>, Data, undefined), Result1);
decode(#{<<"jsonrpc">> := ?VERSION, <<"result">> := Result} = Data) ->
  Response0 = #{result => Result},
  maybe_add(id, maps:get(<<"id">>, Data, undefined), Response0);
decode(#{<<"jsonrpc">> := ?VERSION, <<"error">> := Error} = Data) ->
  Error0 = #{code => maps:get(<<"code">>, Error)},
  Error1 = maybe_add(message, maps:get(<<"message">>, Error, undefined), Error0),
  Error2 = maybe_add(data, maps:get(<<"data">>, Error, undefined), Error1),
  Response0 = #{error => Error2},
  maybe_add(id, maps:get(<<"id">>, Data, undefined), Response0);
decode(Data) when is_binary(Data) ->
  case json:decode(Data) of
    DecodedData when is_list(DecodedData) ->
      lists:map(fun decode/1, DecodedData);
    DecodedData ->
      decode(DecodedData)
  end;
decode(Data) when is_list(Data) ->
  decode(list_to_binary(Data));
decode(_) ->
  % need to convert it here, otherwise list function clause will triggered
  list_to_binary(error_response(?PARSE_ERROR, <<"Parse error">>, null)).

-spec notification(binary()) -> iodata().
notification(Method) ->
  request(Method, undefined, undefined).

-spec notification(binary(), params()) -> iodata().
notification(Method, Params) ->
  request(Method, Params, undefined).

-spec request(method(), params(), id() | undefined) ->
  iodata().
request(Method, Params, Id) when is_binary(Method) ->
  Command0 = #{jsonrpc => ?VERSION,
               method => Method},
  Command1 = maybe_add(params, Params, Command0),
  Command2 = maybe_add(id, Id, Command1),
  json:encode(Command2);
request(Method, Params, Id) when is_list(Method) ->
  request(list_to_binary(Method), Params, Id).

-spec response(term(), id()) -> iodata().
response(Result, Id) ->
  Response = #{jsonrpc => ?VERSION,
               result => Result,
               id => Id},
  json:encode(Response).

-spec error_response(integer(), binary(), id()) -> iodata().
error_response(Code, Message, Id) ->
  error_response(Code, Message, Id, undefined).

-spec error_response(integer(), binary(), id(), term() | undefined) -> iodata().
error_response(Code, Message, Id, ErrorData)  when is_binary(Message) ->
  Response = #{jsonrpc => ?VERSION,
               error => maybe_add(data, ErrorData, #{code => Code, message => Message}),
               id => Id},
  json:encode(Response).

-spec maybe_add(atom(), term() | undefined, map()) -> map().
maybe_add(_Key, undefined, Acc) ->
  Acc;
maybe_add(Key, Value, Acc) ->
  Acc#{Key => Value}.

execute(#{method := Method} = DecodedRequest) when is_binary(Method) ->
  Id = maps:get(id, DecodedRequest, null),
  case persistent_term:get({?MODULE, Method}, undefined) of
    undefined ->
      error_response(?METHOD_NOT_FOUND, <<"Method not found">>, Id);
    Function ->
      try execute(Function, maps:get(params, DecodedRequest, undefined)) of
        {ok, Result} ->
          response(Result, Id);
        ok -> % notification of calls where we do not want to response
          no_response;
        {error, {Code, Message}} ->
          error_response(Code, Message, Id);
        {error, {Code, Message, Data}} ->
          error_response(Code, Message, Id, Data);
        {error, Data} ->
          error_response(?INTERNAL_ERROR, <<"Internal error">>, Id, Data);
        Else ->
          error_response(?INTERNAL_ERROR, <<"Internal error">>, Id, {not_proper_response, Else})
      catch
        T:E:_ST ->
          error_response(?INTERNAL_ERROR, <<"Internal error">>, Id, io_lib:bformat("~p ~p", [T, E]))
      end
  end;
execute([]) ->
  list_to_binary(error_response(?INVALID_REQUEST, <<"Invalid Request">>, null));
execute(Requests) when is_list(Requests) ->
  gather_results(lists:map(fun spawn_execute/1, Requests), ["]"]);
execute(_) ->
  error_response(?INVALID_REQUEST, <<"Invalid Request">>, null).

spawn_execute(Request) ->
  Parent = self(),
  Ref2 = make_ref(),
  {Pid, Ref} = spawn_monitor(fun() -> Parent ! {Ref2, execute(Request)} end),
  {Pid, Ref, Ref2}.

gather_results([{Pid, Ref, Ref2}], Acc) ->
  EndResult = receive
                {Ref2, Result} ->
                  erlang:demonitor(Ref, [flush]),
                  Result;
                {'DOWN', Ref, process, Pid, Reason} ->
                  error_response(?INTERNAL_ERROR, <<"Internal error">>, null, Reason)
              end,
  case EndResult of
    no_response ->
      gather_results([], Acc);
    _ ->
      gather_results([], ["[", [EndResult | Acc]])
  end;
gather_results([{Pid, Ref, Ref2} | Rest], Acc) ->
  EndResult = receive
                {Ref2, Result} ->
                  erlang:demonitor(Ref, [flush]),
                  Result;
                {'DOWN', Ref, process, Pid, Reason} ->
                  error_response(?INTERNAL_ERROR, <<"Internal error">>, null, Reason)
              end,
  case EndResult of
    no_response ->
      gather_results(Rest, Acc);
    _ ->
      gather_results(Rest, ["," | [EndResult | Acc]])
  end;
gather_results([], ["]"]) ->
  % in case of empty response
  no_response;
gather_results([], Acc) ->
  Acc.

-spec execute(function(), params()) -> term().
execute(Function, undefined) ->
  erlang:apply(Function, []);
execute(Function, Params) when is_list(Params) ->
  erlang:apply(Function, Params);
execute(Function, Params) when is_map(Params) ->
  erlang:apply(Function, [Params]);
execute(_Function, _Params) ->
  {error, {?INVALID_REQUEST, <<"Invalid Request">>}}.