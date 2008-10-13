%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd.,
%%   Cohesive Financial Technologies LLC., and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd., Cohesive Financial Technologies
%%   LLC., and Rabbit Technologies Ltd. are Copyright (C) 2007-2008
%%   LShift Ltd., Cohesive Financial Technologies LLC., and Rabbit
%%   Technologies Ltd.;
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_exchange).
-include_lib("stdlib/include/qlc.hrl").
-include("rabbit.hrl").
-include("rabbit_framing.hrl").

-export([recover/0, declare/5, lookup/1, lookup_or_die/1,
         list_vhost_exchanges/1,
         simple_publish/6, simple_publish/3,
         route/2]).
-export([add_binding/4, delete_binding/4]).
-export([delete/2]).
-export([delete_bindings_for_queue/1]).
-export([check_type/1, assert_type/2, topic_matches/2]).

%% EXTENDED API
-export([list_exchange_bindings/1]).

-import(mnesia).
-import(sets).
-import(lists).
-import(qlc).
-import(regexp).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(publish_res() :: {'ok', [pid()]} |
      not_found() | {'error', 'unroutable' | 'not_delivered'}).
-type(bind_res() :: 'ok' |
      {'error', 'queue_not_found' | 'exchange_not_found'}).
-spec(recover/0 :: () -> 'ok').
-spec(declare/5 :: (exchange_name(), exchange_type(), bool(), bool(),
                    amqp_table()) -> exchange()).
-spec(check_type/1 :: (binary()) -> atom()).
-spec(assert_type/2 :: (exchange(), atom()) -> 'ok').
-spec(lookup/1 :: (exchange_name()) -> {'ok', exchange()} | not_found()).
-spec(lookup_or_die/1 :: (exchange_name()) -> exchange()).
-spec(list_vhost_exchanges/1 :: (vhost()) -> [exchange()]).
-spec(simple_publish/6 ::
      (bool(), bool(), exchange_name(), routing_key(), binary(), binary()) ->
             publish_res()).
-spec(simple_publish/3 :: (bool(), bool(), message()) -> publish_res()).
-spec(route/2 :: (exchange(), routing_key()) -> [pid()]).
-spec(add_binding/4 ::
      (exchange_name(), queue_name(), routing_key(), amqp_table()) ->
             bind_res() | {'error', 'durability_settings_incompatible'}).
-spec(delete_binding/4 ::
      (exchange_name(), queue_name(), routing_key(), amqp_table()) ->
             bind_res() | {'error', 'binding_not_found'}).
-spec(delete_bindings_for_queue/1 :: (queue_name()) -> 'ok').
-spec(topic_matches/2 :: (binary(), binary()) -> bool()).
-spec(delete/2 :: (exchange_name(), bool()) ->
             'ok' | not_found() | {'error', 'in_use'}).

-endif.

%%----------------------------------------------------------------------------

recover() ->
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              mnesia:foldl(
                fun (Exchange, Acc) ->
                        ok = mnesia:write(Exchange),
                        Acc
                end, ok, durable_exchanges),
              mnesia:foldl(
                fun (Route, Acc) ->
                        {_, ReverseRoute} = route_with_reverse(Route),
                        ok = mnesia:write(Route),
                        ok = mnesia:write(ReverseRoute),
                        Acc
                end, ok, durable_routes),
              ok
      end).

declare(ExchangeName, Type, Durable, AutoDelete, Args) ->
    Exchange = #exchange{name = ExchangeName,
                         type = Type,
                         durable = Durable,
                         auto_delete = AutoDelete,
                         arguments = Args},
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              case mnesia:wread({exchange, ExchangeName}) of
                  [] -> ok = mnesia:write(Exchange),
                        if Durable ->
                                ok = mnesia:write(
                                       durable_exchanges, Exchange, write);
                           true -> ok
                        end,
                        Exchange;
                  [ExistingX] -> ExistingX
              end
      end).

check_type(<<"fanout">>) ->
    fanout;
check_type(<<"direct">>) ->
    direct;
check_type(<<"topic">>) ->
    topic;
check_type(T) ->
    rabbit_misc:protocol_error(
      command_invalid, "invalid exchange type '~s'", [T]).

assert_type(#exchange{ type = ActualType }, RequiredType)
  when ActualType == RequiredType ->
    ok;
assert_type(#exchange{ name = Name, type = ActualType }, RequiredType) ->
    rabbit_misc:protocol_error(
      not_allowed, "cannot redeclare ~s of type '~s' with type '~s'",
      [rabbit_misc:rs(Name), ActualType, RequiredType]).

lookup(Name) ->
    rabbit_misc:dirty_read({exchange, Name}).

lookup_or_die(Name) ->
    case lookup(Name) of
        {ok, X} -> X;
        {error, not_found} ->
            rabbit_misc:protocol_error(
              not_found, "no ~s", [rabbit_misc:rs(Name)])
    end.

list_vhost_exchanges(VHostPath) ->
    mnesia:dirty_match_object(
      #exchange{name = rabbit_misc:r(VHostPath, exchange), _ = '_'}).

%% Usable by Erlang code that wants to publish messages.
simple_publish(Mandatory, Immediate, ExchangeName, RoutingKeyBin,
               ContentTypeBin, BodyBin) ->
    {ClassId, _MethodId} = rabbit_framing:method_id('basic.publish'),
    Content = #content{class_id = ClassId,
                       properties = #'P_basic'{content_type = ContentTypeBin},
                       properties_bin = none,
                       payload_fragments_rev = [BodyBin]},
    Message = #basic_message{exchange_name = ExchangeName,
                             routing_key = RoutingKeyBin,
                             content = Content,
                             persistent_key = none},
    simple_publish(Mandatory, Immediate, Message).

%% Usable by Erlang code that wants to publish messages.
simple_publish(Mandatory, Immediate,
               Message = #basic_message{exchange_name = ExchangeName,
                                        routing_key = RoutingKey}) ->
    case lookup(ExchangeName) of
        {ok, Exchange} ->
            QPids = route(Exchange, RoutingKey),
            rabbit_router:deliver(QPids, Mandatory, Immediate,
                                  none, Message);
        {error, Error} -> {error, Error}
    end.

%% return the list of qpids to which a message with a given routing
%% key, sent to a particular exchange, should be delivered.
%%
%% The function ensures that a qpid appears in the return list exactly
%% as many times as a message should be delivered to it. With the
%% current exchange types that is at most once.
%%
%% TODO: Maybe this should be handled by a cursor instead.
route(#exchange{name = Name, type = topic}, RoutingKey) ->
    Query = qlc:q([QName ||
                      #route{binding = #binding{
                               exchange_name = ExchangeName,
                               queue_name = QName,
                               key = BindingKey}} <- mnesia:table(route),
                      ExchangeName == Name,
                      %% TODO: This causes a full scan for each entry
                      %% with the same exchange  (see bug 19336)
                      topic_matches(BindingKey, RoutingKey)]),
    lookup_qpids(mnesia:async_dirty(fun qlc:e/1, [Query]));

route(X = #exchange{type = fanout}, _) ->
    route_internal(X, '_');

route(X = #exchange{type = direct}, RoutingKey) ->
    route_internal(X, RoutingKey).

route_internal(#exchange{name = Name}, RoutingKey) ->
    MatchHead = #route{binding = #binding{exchange_name = Name,
                                          queue_name = '$1',
                                          key = RoutingKey,
                                          args = '_'}},
    lookup_qpids(mnesia:dirty_select(route, [{MatchHead, [], ['$1']}])).

lookup_qpids(Queues) ->
    sets:fold(
      fun(Key, Acc) ->
              [#amqqueue{pid = QPid}] = mnesia:dirty_read({amqqueue, Key}),
              [QPid | Acc]
      end, [], sets:from_list(Queues)).

%% TODO: Should all of the route and binding management not be
%% refactored to its own module, especially seeing as unbind will have
%% to be implemented for 0.91 ?

delete_bindings_for_exchange(ExchangeName) ->
    indexed_delete(
      #route{binding = #binding{exchange_name = ExchangeName,
                                queue_name = '_',
                                key = '_',
                                args = '_'}}, 
      fun delete_forward_routes/1, fun mnesia:delete_object/1).

delete_bindings_for_queue(QueueName) ->
    Exchanges = exchanges_for_queue(QueueName),
    indexed_delete(
      reverse_route(#route{binding = #binding{exchange_name = '_',
                                              queue_name = QueueName, 
                                              key = '_',
                                              args = '_'}}),
      fun mnesia:delete_object/1, fun delete_forward_routes/1),
    [begin
         [X] = mnesia:read({exchange, ExchangeName}),
         ok = maybe_auto_delete(X)
     end || ExchangeName <- Exchanges],
    ok.

indexed_delete(Match, ForwardsDeleteFun, ReverseDeleteFun) ->    
    [begin
         ok = ReverseDeleteFun(reverse_route(Route)),
         ok = ForwardsDeleteFun(Route)
     end || Route <- mnesia:match_object(Match)],
    ok.

delete_forward_routes(Route) ->
    ok = mnesia:delete_object(Route),
    ok = mnesia:delete_object(durable_routes, Route, write).

exchanges_for_queue(QueueName) ->
    MatchHead = reverse_route(
                  #route{binding = #binding{exchange_name = '$1',
                                            queue_name = QueueName,
                                            key = '_',
                                            args = '_'}}),
    sets:to_list(
      sets:from_list(
        mnesia:select(reverse_route, [{MatchHead, [], ['$1']}]))).

has_bindings(ExchangeName) ->
    MatchHead = #route{binding = #binding{exchange_name = ExchangeName,
                                          queue_name = '$1',
                                          key = '_',
                                          args = '_'}},
    continue(mnesia:select(route, [{MatchHead, [], ['$1']}], 1, read)).

continue('$end_of_table')    -> false;
continue({[_|_], _})         -> true;
continue({[], Continuation}) -> continue(mnesia:select(Continuation)).

call_with_exchange(Exchange, Fun) ->
    rabbit_misc:execute_mnesia_transaction(
      fun() -> case mnesia:read({exchange, Exchange}) of
                   []  -> {error, exchange_not_found};
                   [X] -> Fun(X)
               end
      end).

call_with_exchange_and_queue(Exchange, Queue, Fun) ->
    call_with_exchange(
      Exchange, 
      fun(X) -> case mnesia:read({amqqueue, Queue}) of
                    []  -> {error, queue_not_found};
                    [Q] -> Fun(X, Q)
                end
      end).

add_binding(ExchangeName, QueueName, RoutingKey, Arguments) ->
    call_with_exchange_and_queue(
      ExchangeName, QueueName,
      fun (X, Q) ->
              if Q#amqqueue.durable and not(X#exchange.durable) ->
                      {error, durability_settings_incompatible};
                 true -> ok = sync_binding(
                            ExchangeName, QueueName, RoutingKey, Arguments,
                            Q#amqqueue.durable, fun mnesia:write/3)
              end
      end).

delete_binding(ExchangeName, QueueName, RoutingKey, Arguments) ->
    call_with_exchange_and_queue(
      ExchangeName, QueueName,
      fun (X, Q) ->
              ok = sync_binding(
                     ExchangeName, QueueName, RoutingKey, Arguments,
                     Q#amqqueue.durable, fun mnesia:delete_object/3),
              maybe_auto_delete(X)
      end).

sync_binding(ExchangeName, QueueName, RoutingKey, Arguments, Durable, Fun) ->
    Binding = #binding{exchange_name = ExchangeName,
                       queue_name = QueueName,
                       key = RoutingKey,
                       args = Arguments},
    ok = case Durable of
             true  -> Fun(durable_routes, #route{binding = Binding}, write);
             false -> ok
         end,
    [ok, ok] = [Fun(element(1, R), R, write) ||
                   R <- tuple_to_list(route_with_reverse(Binding))],
    ok.

route_with_reverse(#route{binding = Binding}) ->
    route_with_reverse(Binding);
route_with_reverse(Binding = #binding{}) ->
    Route = #route{binding = Binding},
    {Route, reverse_route(Route)}.

reverse_route(#route{binding = Binding}) ->
    #reverse_route{reverse_binding = reverse_binding(Binding)};

reverse_route(#reverse_route{reverse_binding = Binding}) ->
    #route{binding = reverse_binding(Binding)}.

reverse_binding(#reverse_binding{exchange_name = Exchange,
                                 queue_name = Queue,
                                 key = Key,
                                 args = Args}) ->
    #binding{exchange_name = Exchange,
             queue_name = Queue,
             key = Key,
             args = Args};

reverse_binding(#binding{exchange_name = Exchange,
                         queue_name = Queue,
                         key = Key,
                         args = Args}) ->
    #reverse_binding{exchange_name = Exchange,
                     queue_name = Queue,
                     key = Key,
                     args = Args}.

split_topic_key(Key) ->
    {ok, KeySplit} = regexp:split(binary_to_list(Key), "\\."),
    KeySplit.

topic_matches(PatternKey, RoutingKey) ->
    P = split_topic_key(PatternKey),
    R = split_topic_key(RoutingKey),
    topic_matches1(P, R).

topic_matches1(["#"], _R) ->
    true;
topic_matches1(["#" | PTail], R) ->
    last_topic_match(PTail, [], lists:reverse(R));
topic_matches1([], []) ->
    true;
topic_matches1(["*" | PatRest], [_ | ValRest]) ->
    topic_matches1(PatRest, ValRest);
topic_matches1([PatElement | PatRest], [ValElement | ValRest]) when PatElement == ValElement ->
    topic_matches1(PatRest, ValRest);
topic_matches1(_, _) ->
    false.

last_topic_match(P, R, []) ->
    topic_matches1(P, R);
last_topic_match(P, R, [BacktrackNext | BacktrackList]) ->
    topic_matches1(P, R) or last_topic_match(P, [BacktrackNext | R], BacktrackList).

delete(ExchangeName, _IfUnused = true) ->
    call_with_exchange(ExchangeName, fun conditional_delete/1);
delete(ExchangeName, _IfUnused = false) ->
    call_with_exchange(ExchangeName, fun unconditional_delete/1).

maybe_auto_delete(#exchange{auto_delete = false}) ->
    ok;
maybe_auto_delete(Exchange = #exchange{auto_delete = true}) ->
    conditional_delete(Exchange),
    ok.

conditional_delete(Exchange = #exchange{name = ExchangeName}) ->
    case has_bindings(ExchangeName) of
        false  -> unconditional_delete(Exchange);
        true   -> {error, in_use}
    end.

unconditional_delete(#exchange{name = ExchangeName}) ->
    ok = delete_bindings_for_exchange(ExchangeName),
    ok = mnesia:delete({durable_exchanges, ExchangeName}),
    ok = mnesia:delete({exchange, ExchangeName}).

%%----------------------------------------------------------------------------
%% EXTENDED API
%% These are API calls that are not used by the server internally,
%% they are exported for embedded clients to use

%% This is currently used in mod_rabbit.erl (XMPP) and expects this to
%% return {QueueName, RoutingKey, Arguments} tuples
list_exchange_bindings(ExchangeName) ->
    Route = #route{binding = #binding{exchange_name = ExchangeName,
                                      queue_name = '_',
                                      key = '_',
                                      args = '_'}},
    [{QueueName, RoutingKey, Arguments} ||
        #route{binding = #binding{queue_name = QueueName,
                                  key = RoutingKey,
                                  args = Arguments}} 
            <- mnesia:dirty_match_object(Route)].
