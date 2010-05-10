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
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_amqqueue).

-export([start/0, declare/5, delete/3, purge/1]).
-export([internal_declare/2, internal_delete/1]).
-export([pseudo_queue/2]).
-export([lookup/1, with/2, with_or_die/2,
         stat/1, stat_all/0, deliver/2, requeue/3, ack/4]).
-export([list/1, info_keys/0, info/1, info/2, info_all/1, info_all/2]).
-export([consumers/1, consumers_all/1]).
-export([basic_get/3, basic_consume/7, basic_cancel/4]).
-export([notify_sent/2, unblock/2, flush_all/2]).
-export([commit_all/3, rollback_all/3, notify_down_all/2, limit_all/3]).
-export([on_node_down/1]).

-import(mnesia).
-import(gen_server2).
-import(lists).
-import(queue).

-include("rabbit.hrl").
-include_lib("stdlib/include/qlc.hrl").

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(qstats() :: {'ok', queue_name(), non_neg_integer(), non_neg_integer()}).
-type(qlen() :: {'ok', non_neg_integer()}).
-type(qfun(A) :: fun ((amqqueue()) -> A)).
-type(ok_or_errors() ::
      'ok' | {'error', [{'error' | 'exit' | 'throw', any()}]}).

-spec(start/0 :: () -> 'ok').
-spec(declare/5 :: (queue_name(), boolean(), boolean(), amqp_table(), maybe(pid())) ->
             amqqueue()).
-spec(lookup/1 :: (queue_name()) -> {'ok', amqqueue()} | not_found()).
-spec(with/2 :: (queue_name(), qfun(A)) -> A | not_found()).
-spec(with_or_die/2 :: (queue_name(), qfun(A)) -> A).
-spec(list/1 :: (vhost()) -> [amqqueue()]).
-spec(info_keys/0 :: () -> [info_key()]).
-spec(info/1 :: (amqqueue()) -> [info()]).
-spec(info/2 :: (amqqueue(), [info_key()]) -> [info()]).
-spec(info_all/1 :: (vhost()) -> [[info()]]).
-spec(info_all/2 :: (vhost(), [info_key()]) -> [[info()]]).
-spec(consumers/1 :: (amqqueue()) -> [{pid(), ctag(), boolean()}]).
-spec(consumers_all/1 ::
      (vhost()) -> [{queue_name(), pid(), ctag(), boolean()}]).
-spec(stat/1 :: (amqqueue()) -> qstats()).
-spec(stat_all/0 :: () -> [qstats()]).
-spec(delete/3 ::
      (amqqueue(), 'false', 'false') -> qlen();
      (amqqueue(), 'true' , 'false') -> qlen() | {'error', 'in_use'};
      (amqqueue(), 'false', 'true' ) -> qlen() | {'error', 'not_empty'};
      (amqqueue(), 'true' , 'true' ) -> qlen() |
                                            {'error', 'in_use'} |
                                            {'error', 'not_empty'}).
-spec(purge/1 :: (amqqueue()) -> qlen()).
-spec(deliver/2 :: (pid(), delivery()) -> boolean()).
-spec(requeue/3 :: (pid(), [msg_id()],  pid()) -> 'ok').
-spec(ack/4 :: (pid(), maybe(txn()), [msg_id()], pid()) -> 'ok').
-spec(commit_all/3 :: ([pid()], txn(), pid()) -> ok_or_errors()).
-spec(rollback_all/3 :: ([pid()], txn(), pid()) -> 'ok').
-spec(notify_down_all/2 :: ([pid()], pid()) -> ok_or_errors()).
-spec(limit_all/3 :: ([pid()], pid(), pid() | 'undefined') -> ok_or_errors()).
-spec(basic_get/3 :: (amqqueue(), pid(), boolean()) ->
             {'ok', non_neg_integer(), qmsg()} | 'empty').
-spec(basic_consume/7 ::
      (amqqueue(), boolean(), pid(), pid() | 'undefined', ctag(),
       boolean(), any()) ->
             'ok' | {'error', 'queue_owned_by_another_connection' |
                     'exclusive_consume_unavailable'}).
-spec(basic_cancel/4 :: (amqqueue(), pid(), ctag(), any()) -> 'ok').
-spec(notify_sent/2 :: (pid(), pid()) -> 'ok').
-spec(unblock/2 :: (pid(), pid()) -> 'ok').
-spec(flush_all/2 :: ([pid()], pid()) -> 'ok').
-spec(internal_declare/2 :: (amqqueue(), boolean()) -> amqqueue()).
-spec(internal_delete/1 :: (queue_name()) -> 'ok' | not_found()).
-spec(on_node_down/1 :: (erlang_node()) -> 'ok').
-spec(pseudo_queue/2 :: (binary(), pid()) -> amqqueue()).

-endif.

%%----------------------------------------------------------------------------

start() ->
    DurableQueues = find_durable_queues(),
    ok = rabbit_sup:start_child(
           rabbit_persister,
           [[QName || #amqqueue{name = QName} <- DurableQueues]]),
    {ok,_} = supervisor:start_child(
               rabbit_sup,
               {rabbit_amqqueue_sup,
                {rabbit_amqqueue_sup, start_link, []},
                transient, infinity, supervisor, [rabbit_amqqueue_sup]}),
    _RealDurableQueues = recover_durable_queues(DurableQueues),
    ok.

find_durable_queues() ->
    Node = node(),
    %% TODO: use dirty ops instead
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              qlc:e(qlc:q([Q || Q = #amqqueue{pid = Pid}
                                    <- mnesia:table(rabbit_durable_queue),
                                node(Pid) == Node]))
      end).

recover_durable_queues(DurableQueues) ->
    Qs = [start_queue_process(Q) || Q <- DurableQueues],
    %% Issue inits to *all* the queues so that they all init at the same time
    [ok = gen_server2:cast(Q#amqqueue.pid, {init, true}) || Q <- Qs],
    [ok = gen_server2:call(Q#amqqueue.pid, sync, infinity) || Q <- Qs],
    rabbit_misc:execute_mnesia_transaction(
      fun () -> [ok = store_queue(Q) || Q <- Qs] end),
    Qs.

declare(QueueName, Durable, AutoDelete, Args, Owner) ->
    Q = start_queue_process(#amqqueue{name = QueueName,
                                      durable = Durable,
                                      auto_delete = AutoDelete,
                                      arguments = Args,
                                      exclusive_owner = Owner,
                                      pid = none}),
    ok = gen_server2:cast(Q#amqqueue.pid, {init, false}),
    ok = gen_server2:call(Q#amqqueue.pid, sync, infinity),
    Q2 = internal_declare(Q, true),
    %% We need to notify the reader within the channel process so that we can
    %% be sure there are no outstanding exclusive queues being declared as the
    %% connection shuts down.
    case Owner of
        none -> Q2;
        _    ->
            Owner ! {notify_exclusive_queue, Q#amqqueue.pid},
            Q2
    end.

internal_declare(Q = #amqqueue{name = QueueName}, WantDefaultBinding) ->
    case rabbit_misc:execute_mnesia_transaction(
           fun () ->
                   case mnesia:wread({rabbit_queue, QueueName}) of
                       [] ->
                           case mnesia:read(
                                  {rabbit_durable_queue, QueueName}) of
                               []  -> ok = store_queue(Q),
                                      case WantDefaultBinding of
                                          true  -> add_default_binding(Q);
                                          false -> ok
                                      end,
                                      Q;
                               [_] -> not_found %% existing Q on stopped node
                           end;
                       [ExistingQ] ->
                           ExistingQ
                   end
           end) of
        not_found -> exit(Q#amqqueue.pid, shutdown),
                     rabbit_misc:not_found(QueueName);
        Q         -> Q;
        ExistingQ -> exit(Q#amqqueue.pid, shutdown),
                     ExistingQ
    end.

store_queue(Q = #amqqueue{durable = true}) ->
    ok = mnesia:write(rabbit_durable_queue, Q, write),
    ok = mnesia:write(rabbit_queue, Q, write),
    ok;
store_queue(Q = #amqqueue{durable = false}) ->
    ok = mnesia:write(rabbit_queue, Q, write),
    ok.

start_queue_process(Q) ->
    {ok, Pid} = rabbit_amqqueue_sup:start_child([Q]),
    Q#amqqueue{pid = Pid}.

add_default_binding(#amqqueue{name = QueueName}) ->
    Exchange = rabbit_misc:r(QueueName, exchange, <<>>),
    RoutingKey = QueueName#resource.name,
    rabbit_exchange:add_binding(Exchange, QueueName, RoutingKey, [], fun (_X, _Q) -> ok end),
    ok.

lookup(Name) ->
    rabbit_misc:dirty_read({rabbit_queue, Name}).

with(Name, F, E) ->
    case lookup(Name) of
        {ok, Q} -> rabbit_misc:with_exit_handler(E, fun () -> F(Q) end);
        {error, not_found} -> E()
    end.

with(Name, F) ->
    with(Name, F, fun () -> {error, not_found} end).
with_or_die(Name, F) ->
    with(Name, F, fun () -> rabbit_misc:not_found(Name) end).

list(VHostPath) ->
    mnesia:dirty_match_object(
      rabbit_queue,
      #amqqueue{name = rabbit_misc:r(VHostPath, queue), _ = '_'}).

info_keys() -> rabbit_amqqueue_process:info_keys().

map(VHostPath, F) -> rabbit_misc:filter_exit_map(F, list(VHostPath)).

info(#amqqueue{ pid = QPid }) ->
    delegate_pcall(QPid, 9, info, infinity).

info(#amqqueue{ pid = QPid }, Items) ->
    case delegate_pcall(QPid, 9, {info, Items}, infinity) of
        {ok, Res}      -> Res;
        {error, Error} -> throw(Error)
    end.

info_all(VHostPath) -> map(VHostPath, fun (Q) -> info(Q) end).

info_all(VHostPath, Items) -> map(VHostPath, fun (Q) -> info(Q, Items) end).

consumers(#amqqueue{ pid = QPid }) ->
    delegate_pcall(QPid, 9, consumers, infinity).

consumers_all(VHostPath) ->
    lists:concat(
      map(VHostPath,
          fun (Q) -> [{Q#amqqueue.name, ChPid, ConsumerTag, AckRequired} ||
                         {ChPid, ConsumerTag, AckRequired} <- consumers(Q)]
          end)).

stat(#amqqueue{pid = QPid}) -> delegate_call(QPid, stat, infinity).

stat_all() ->
    lists:map(fun stat/1, rabbit_misc:dirty_read_all(rabbit_queue)).

delete(#amqqueue{ pid = QPid, exclusive_owner = Owner }, IfUnused, IfEmpty) ->
    Res = delegate_call(QPid, {delete, IfUnused, IfEmpty}, infinity),
    %% We need to notify the reader within the channel process so that we can
    %% be sure there are no outstanding exclusive queues being deleted as the
    %% connection shuts down.
    case Owner of
        none -> Res;
        _    ->
            Owner ! {delete_exclusive_queue, QPid},
            Res
    end.

purge(#amqqueue{ pid = QPid }) -> delegate_call(QPid, purge, infinity).

deliver(QPid, #delivery{immediate = true,
                        txn = Txn, sender = ChPid, message = Message}) ->
    gen_server2:call(QPid, {deliver_immediately, Txn, Message, ChPid},
                     infinity);
deliver(QPid, #delivery{mandatory = true,
                        txn = Txn, sender = ChPid, message = Message}) ->
    gen_server2:call(QPid, {deliver, Txn, Message, ChPid}, infinity),
    true;
deliver(QPid, #delivery{txn = Txn, sender = ChPid, message = Message}) ->
    gen_server2:cast(QPid, {deliver, Txn, Message, ChPid}),
    true.

requeue(QPid, MsgIds, ChPid) ->
    delegate_call(QPid, {requeue, MsgIds, ChPid}, infinity).

ack(QPid, Txn, MsgIds, ChPid) ->
    delegate_pcast(QPid, 7, {ack, Txn, MsgIds, ChPid}).

commit_all(QPids, Txn, ChPid) ->
    safe_delegate_call_ok(
      fun (QPid) -> exit({queue_disappeared, QPid}) end,
      fun (QPid) -> gen_server2:call(QPid, {commit, Txn, ChPid}, infinity) end,
      QPids).

rollback_all(QPids, Txn, ChPid) ->
    delegate:invoke_no_result(
      QPids, fun (QPid) -> gen_server2:cast(QPid, {rollback, Txn, ChPid}) end).

notify_down_all(QPids, ChPid) ->
    safe_delegate_call_ok(
      %% we don't care if the queue process has terminated in the
      %% meantime
      fun (_)    -> ok end,
      fun (QPid) -> gen_server2:call(QPid, {notify_down, ChPid}, infinity) end,
      QPids).

limit_all(QPids, ChPid, LimiterPid) ->
    delegate:invoke_no_result(
      QPids, fun (QPid) ->
                     gen_server2:cast(QPid, {limit, ChPid, LimiterPid})
             end).

basic_get(#amqqueue{pid = QPid}, ChPid, NoAck) ->
    delegate_call(QPid, {basic_get, ChPid, NoAck}, infinity).

basic_consume(#amqqueue{pid = QPid}, NoAck, ChPid, LimiterPid,
              ConsumerTag, ExclusiveConsume, OkMsg) ->
    delegate_call(QPid, {basic_consume, NoAck, ChPid,
                            LimiterPid, ConsumerTag, ExclusiveConsume, OkMsg},
                  infinity).

basic_cancel(#amqqueue{pid = QPid}, ChPid, ConsumerTag, OkMsg) ->
    ok = delegate_call(QPid, {basic_cancel, ChPid, ConsumerTag, OkMsg},
                       infinity).

notify_sent(QPid, ChPid) ->
    delegate_pcast(QPid, 7, {notify_sent, ChPid}).

unblock(QPid, ChPid) ->
    delegate_pcast(QPid, 7, {unblock, ChPid}).

flush_all(QPids, ChPid) ->
    delegate:invoke_no_result(
      QPids, fun (QPid) -> gen_server2:cast(QPid, {flush, ChPid}) end).

internal_delete2(QueueName) ->
    ok = mnesia:delete({rabbit_queue, QueueName}),
    ok = mnesia:delete({rabbit_durable_queue, QueueName}),
    %% this is last because it returns a post-transaction callback
    rabbit_exchange:delete_queue_bindings(QueueName).

internal_delete(QueueName) ->
    case
        rabbit_misc:execute_mnesia_transaction(
          fun () ->
                  case mnesia:wread({rabbit_queue, QueueName}) of
                      []  -> {error, not_found};
                      [_] -> internal_delete2(QueueName)
                  end
          end) of
        Err = {error, _} ->
            Err;
        %% we want to execute some things, as
        %% decided by rabbit_exchange, after the
        %% transaction.
        PostHook ->
            PostHook(),
            ok
    end.

on_node_down(Node) ->
    [Hook() ||
        Hook <- rabbit_misc:execute_mnesia_transaction(
                  fun () ->
                          qlc:e(qlc:q([delete_queue(QueueName) ||
                                          #amqqueue{name = QueueName, pid = Pid}
                                              <- mnesia:table(rabbit_queue),
                                          node(Pid) == Node]))
                  end)],
    ok.

delete_queue(QueueName) ->
    Post = rabbit_exchange:delete_transient_queue_bindings(QueueName),
    ok = mnesia:delete({rabbit_queue, QueueName}),
    Post.

pseudo_queue(QueueName, Pid) ->
    #amqqueue{name = QueueName,
              durable = false,
              auto_delete = false,
              arguments = [],
              pid = Pid}.

safe_delegate_call_ok(H, F, Pids) ->
    {_, Bad} = delegate:invoke(Pids,
                               fun (Pid) ->
                                       rabbit_misc:with_exit_handler(
                                         fun () -> H(Pid) end,
                                         fun () -> F(Pid) end)
                               end),
    case Bad of
        [] -> ok;
        _  -> {error, Bad}
    end.

delegate_call(Pid, Msg, Timeout) ->
    delegate:invoke(Pid, fun(P) -> gen_server2:call(P, Msg, Timeout) end).

delegate_pcall(Pid, Pri, Msg, Timeout) ->
    delegate:invoke(Pid, fun(P) -> gen_server2:pcall(P, Pri, Msg, Timeout) end).

delegate_pcast(Pid, Pri, Msg) ->
    delegate:invoke_no_result(Pid,
                              fun(P) -> gen_server2:pcast(P, Pri, Msg) end).

