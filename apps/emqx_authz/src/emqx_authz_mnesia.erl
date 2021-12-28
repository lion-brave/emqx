%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_authz_mnesia).

-include_lib("emqx/include/emqx.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("emqx/include/logger.hrl").

-define(ACL_SHARDED, emqx_acl_sharded).

-define(ACL_TABLE, emqx_acl).

%% To save some space, use an integer for label, 0 for 'all', {1, Username} and {2, ClientId}.
-define(ACL_TABLE_ALL, 0).
-define(ACL_TABLE_USERNAME, 1).
-define(ACL_TABLE_CLIENTID, 2).

-type(username() :: {username, binary()}).
-type(clientid() :: {clientid, binary()}).
-type(who() :: username() | clientid() | all).

-type(rule() :: {emqx_authz_rule:permission(), emqx_authz_rule:action(), emqx_topic:topic()}).
-type(rules() :: [rule()]).

-record(emqx_acl, {
          who :: ?ACL_TABLE_ALL | {?ACL_TABLE_USERNAME, binary()} | {?ACL_TABLE_CLIENTID, binary()},
          rules :: rules()
         }).

-behaviour(emqx_authz).

%% AuthZ Callbacks
-export([ description/0
        , init/1
        , destroy/1
        , dry_run/1
        , authorize/4
        ]).

%% Management API
-export([ mnesia/1
        , init_tables/0
        , store_rules/2
        , purge_rules/0
        , get_rules/1
        , delete_rules/1
        , list_clientid_rules/0
        , list_username_rules/0
        , record_count/0
        ]).

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

-boot_mnesia({mnesia, [boot]}).

-spec(mnesia(boot | copy) -> ok).
mnesia(boot) ->
    ok = mria:create_table(?ACL_TABLE, [
            {type, ordered_set},
            {rlog_shard, ?ACL_SHARDED},
            {storage, disc_copies},
            {attributes, record_info(fields, ?ACL_TABLE)},
            {storage_properties, [{ets, [{read_concurrency, true}]}]}]).

%%--------------------------------------------------------------------
%% emqx_authz callbacks
%%--------------------------------------------------------------------

description() ->
    "AuthZ with Mnesia".

init(Source) -> Source.

destroy(_Source) -> ok.

dry_run(_Source) -> ok.

authorize(#{username := Username,
            clientid := Clientid
           } = Client, PubSub, Topic, #{type := 'built-in-database'}) ->

    Rules = case mnesia:dirty_read(?ACL_TABLE, {?ACL_TABLE_CLIENTID, Clientid}) of
                [] -> [];
                [#emqx_acl{rules = Rules0}] when is_list(Rules0) -> Rules0
            end
         ++ case mnesia:dirty_read(?ACL_TABLE, {?ACL_TABLE_USERNAME, Username}) of
                [] -> [];
                [#emqx_acl{rules = Rules1}] when is_list(Rules1) -> Rules1
            end
         ++ case mnesia:dirty_read(?ACL_TABLE, ?ACL_TABLE_ALL) of
                [] -> [];
                [#emqx_acl{rules = Rules2}] when is_list(Rules2) -> Rules2
            end,
    do_authorize(Client, PubSub, Topic, Rules).

%%--------------------------------------------------------------------
%% Management API
%%--------------------------------------------------------------------

init_tables() ->
    ok = mria_rlog:wait_for_shards([?ACL_SHARDED], infinity).

-spec(store_rules(who(), rules()) -> ok).
store_rules({username, Username}, Rules) ->
    Record = #emqx_acl{who = {?ACL_TABLE_USERNAME, Username}, rules = Rules},
    mria:dirty_write(Record);
store_rules({clientid, Clientid}, Rules) ->
    Record = #emqx_acl{who = {?ACL_TABLE_CLIENTID, Clientid}, rules = Rules},
    mria:dirty_write(Record);
store_rules(all, Rules) ->
    Record = #emqx_acl{who = ?ACL_TABLE_ALL, rules = Rules},
    mria:dirty_write(Record).

-spec(purge_rules() -> ok).
purge_rules() ->
    ok = lists:foreach(
           fun(Key) ->
                   ok = mria:dirty_delete(?ACL_TABLE, Key)
           end,
           mnesia:dirty_all_keys(?ACL_TABLE)).

-spec(get_rules(who()) -> {ok, rules()} | not_found).
get_rules({username, Username}) ->
    do_get_rules({?ACL_TABLE_USERNAME, Username});
get_rules({clientid, Clientid}) ->
    do_get_rules({?ACL_TABLE_CLIENTID, Clientid});
get_rules(all) ->
    do_get_rules(?ACL_TABLE_ALL).

-spec(delete_rules(who()) -> ok).
delete_rules({username, Username}) ->
    mria:dirty_delete(?ACL_TABLE, {?ACL_TABLE_USERNAME, Username});
delete_rules({clientid, Clientid}) ->
    mria:dirty_delete(?ACL_TABLE, {?ACL_TABLE_CLIENTID, Clientid});
delete_rules(all) ->
    mria:dirty_delete(?ACL_TABLE, ?ACL_TABLE_ALL).

-spec(list_username_rules() -> {mria:table(), ets:match_spec()}).
list_username_rules() ->
    MatchSpec = ets:fun2ms(
                  fun(#emqx_acl{who = {?ACL_TABLE_USERNAME, Username}, rules = Rules}) ->
                          [{username, Username}, {rules, Rules}]
                  end),
    {?ACL_TABLE, MatchSpec}.

-spec(list_clientid_rules() -> {mria:table(), ets:match_spec()}).
list_clientid_rules() ->
    MatchSpec = ets:fun2ms(
                  fun(#emqx_acl{who = {?ACL_TABLE_CLIENTID, Clientid}, rules = Rules}) ->
                          [{clientid, Clientid}, {rules, Rules}]
                  end),
    {?ACL_TABLE, MatchSpec}.

-spec(record_count() -> non_neg_integer()).
record_count() ->
    mnesia:table_info(?ACL_TABLE, size).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

do_get_rules(Key) ->
    case mnesia:dirty_read(?ACL_TABLE, Key) of
        [#emqx_acl{rules = Rules}] -> {ok, Rules};
        [] -> not_found
    end.

do_authorize(_Client, _PubSub, _Topic, []) -> nomatch;
do_authorize(Client, PubSub, Topic, [ {Permission, Action, TopicFilter} | Tail]) ->
    case emqx_authz_rule:match(Client, PubSub, Topic,
                               emqx_authz_rule:compile({Permission, all, Action, [TopicFilter]})
                              ) of
        {matched, Permission} -> {matched, Permission};
        nomatch -> do_authorize(Client, PubSub, Topic, Tail)
    end.