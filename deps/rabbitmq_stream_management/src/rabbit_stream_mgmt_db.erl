%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_stream_mgmt_db).

-include_lib("rabbitmq_stream/include/rabbit_stream_metrics.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-export([get_all_consumers/1, get_all_publishers/1]).
-export([consumer_data/3, publisher_data/2]).
-export([get_connection_consumers/1]).

get_all_consumers(VHosts) ->
  rabbit_mgmt_db:submit(fun(_Interval) -> consumers_stats(VHosts) end).

get_all_publishers(VHosts) ->
  rabbit_mgmt_db:submit(fun(_Interval) -> publishers_stats(VHosts) end).

get_connection_consumers(ConnectionPid) when is_pid(ConnectionPid) ->
  rabbit_mgmt_db:submit(fun(_Interval) -> connection_consumers_stats(ConnectionPid) end).

consumers_stats(VHost) ->
  Data = rabbit_mgmt_db:get_data_from_nodes({rabbit_stream_mgmt_db, consumer_data,
    [VHost, fun consumers_by_vhost/1]}),
  [V || {_, V} <- maps:to_list(Data)].

publishers_stats(VHost) ->
  Data = rabbit_mgmt_db:get_data_from_nodes({rabbit_stream_mgmt_db, publisher_data, [VHost]}),
  [V || {_, V} <- maps:to_list(Data)].

connection_consumers_stats(ConnectionPid) ->
  Data = rabbit_mgmt_db:get_data_from_nodes({rabbit_stream_mgmt_db, consumer_data,
    [ConnectionPid, fun consumers_by_connection/1]}),
  [V || {_, V} <- maps:to_list(Data)].

consumer_data(_Pid, Param, QueryFun) ->
  maps:from_list(
    [begin
       AugmentedConsumer = augment_consumer(C),
       {C, augment_connection_pid(AugmentedConsumer) ++ AugmentedConsumer}
     end
       || C <- QueryFun(Param)]
  ).

publisher_data(_Pid, VHost) ->
  maps:from_list(
    [begin
       AugmentedPublisher = augment_publisher(C),
       {C, augment_connection_pid(AugmentedPublisher) ++ AugmentedPublisher}
     end
      || C <- publishers_by_vhost(VHost)]
  ).

augment_consumer({{Q, ConnPid, SubId}, Props}) ->
  [{queue, format_resource(Q)},
   {connection, ConnPid},
   {subscription_id, SubId} | Props].

augment_publisher({{Q, ConnPid, PubId}, Props}) ->
  [{queue, format_resource(Q)},
    {connection, ConnPid},
    {publisher_id, PubId} | Props].

consumers_by_vhost(VHost) ->
  ets:select(?TABLE_CONSUMER,
    [{{{#resource{virtual_host = '$1', _ = '_'}, '_', '_'}, '_'},
      [{'orelse', {'==', 'all', VHost}, {'==', VHost, '$1'}}],
      ['$_']}]).

publishers_by_vhost(VHost) ->
  ets:select(?TABLE_PUBLISHER,
    [{{{#resource{virtual_host = '$1', _ = '_'}, '_', '_'}, '_'},
      [{'orelse', {'==', 'all', VHost}, {'==', VHost, '$1'}}],
      ['$_']}]).

consumers_by_connection(ConnectionPid) ->
  get_entity_stats(?TABLE_CONSUMER, ConnectionPid).

get_entity_stats(Table, Id) ->
  ets:select(Table, match_entity_spec(Id)).

match_entity_spec(ConnectionId) ->
  [{{{'_', '$1', '_'}, '_'}, [{'==', ConnectionId, '$1'}], ['$_']}].

augment_connection_pid(Consumer) ->
  Pid = rabbit_misc:pget(connection, Consumer),
  Conn = rabbit_mgmt_data:lookup_element(connection_created_stats, Pid, 3),
  ConnDetails = case Conn of
    [] -> %% If the connection has just been opened, we might not yet have the data
      [];
    _ ->
      [{name,         rabbit_misc:pget(name,         Conn)},
       {user,         rabbit_misc:pget(user,         Conn)},
       {node,         rabbit_misc:pget(node,         Conn)},
       {peer_port,    rabbit_misc:pget(peer_port,    Conn)},
       {peer_host,    rabbit_misc:pget(peer_host,    Conn)}]
  end,
  [{connection_details, ConnDetails}].

format_resource(unknown) -> unknown;
format_resource(Res)     -> format_resource(name, Res).

format_resource(_, unknown) ->
  unknown;
format_resource(NameAs, #resource{name = Name, virtual_host = VHost}) ->
  [{NameAs, Name}, {vhost, VHost}].
