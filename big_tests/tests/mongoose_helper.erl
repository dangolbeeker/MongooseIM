-module(mongoose_helper).

%% API

-export([is_odbc_enabled/1]).

-export([auth_modules/0]).

-export([total_offline_messages/0,
         total_offline_messages/1,
         total_active_users/0,
         total_privacy_items/0,
         total_private_items/0,
         total_vcard_items/0,
         total_roster_items/0]).

-export([clear_last_activity/2,
         clear_caps_cache/1]).

-export([kick_everyone/0]).
-export([ensure_muc_clean/0]).
-export([successful_rpc/3]).
-export([logout_user/2]).
-export([connect_component/1,
         connect_component/2,
         disconnect_component/2,
         disconnect_components/2,
         component_start_stream/2,
         component_stream_start/2,
         component_handshake/2]).
-export([get_bjid/1]).

-include_lib("escalus/include/escalus.hrl").
-include_lib("exml/include/exml_stream.hrl").

-define(RPC(M, F, A), escalus_ejabberd:rpc(M, F, A)).

-spec is_odbc_enabled(Host :: binary()) -> boolean().
is_odbc_enabled(Host) ->
    case escalus_ejabberd:rpc(mongoose_rdbms, sql_transaction, [Host, fun erlang:yield/0]) of
        {atomic, _} -> true;
        _ -> false
    end.

-spec auth_modules() -> [atom()].
auth_modules() ->
    Hosts = escalus_ejabberd:rpc(ejabberd_config, get_global_option, [hosts]),
    lists:flatmap(
        fun(Host) ->
            escalus_ejabberd:rpc(ejabberd_auth, auth_modules, [Host])
        end, Hosts).

-spec total_offline_messages() -> integer() | false.
total_offline_messages() ->
    generic_count(mod_offline_backend).

-spec total_offline_messages({binary(), binary()}) -> integer() | false.
total_offline_messages(User) ->
    generic_count(mod_offline_backend, User).

-spec total_active_users() -> integer() | false.
total_active_users() ->
    generic_count(mod_last_backend).

-spec total_privacy_items() -> integer() | false.
total_privacy_items() ->
    generic_count(mod_privacy_backend).

-spec total_private_items() -> integer() | false.
total_private_items() ->
    generic_count(mod_private_backend).

-spec total_vcard_items() -> integer() | false.
total_vcard_items() ->
    generic_count(mod_vcard_backend).

-spec total_roster_items() -> integer() | false.
total_roster_items() ->
    Domain = ct:get_config({hosts, mim, domain}),
    RosterMnesia = ?RPC(gen_mod, is_loaded, [Domain, mod_roster]),
    RosterODBC = ?RPC(gen_mod, is_loaded, [Domain, mod_roster_odbc]),
    case {RosterMnesia, RosterODBC} of
        {true, _} ->
            generic_count_backend(mod_roster_mnesia);
        {_, true} ->
            generic_count_backend(mod_roster_odbc);
        _ ->
            false
    end.

%% Need to clear last_activity after carol (connected over BOSH)
%% It is possible that from time to time the unset_presence_hook,
%% for user connected over BOSH, is called after user removal.
%% This happens when the BOSH session is closed (on server side)
%% after user's removal
%% In such situation the last info is set back
-spec clear_last_activity(list(), atom() | binary() | [atom() | binary()]) -> no_return().
clear_last_activity(Config, User) ->
    S = ct:get_config({hosts, mim, domain}),
    case catch escalus_ejabberd:rpc(gen_mod, is_loaded, [S, mod_last]) of
        true ->
            do_clear_last_activity(Config, User);
        _ ->
            ok
    end.

do_clear_last_activity(Config, User) when is_atom(User)->
    [U, S, _P] = escalus_users:get_usp(Config, carol),
    Acc = new_mongoose_acc(),
    successful_rpc(mod_last, remove_user, [Acc, U, S]);
do_clear_last_activity(_Config, User) when is_binary(User) ->
    U = escalus_utils:get_username(User),
    S = escalus_utils:get_server(User),
    Acc = new_mongoose_acc(),
    successful_rpc(mod_last, remove_user, [Acc, U, S]);
do_clear_last_activity(Config, Users) when is_list(Users) ->
    lists:foreach(fun(User) -> do_clear_last_activity(Config, User) end, Users).

new_mongoose_acc() ->
    successful_rpc(mongoose_acc, new, []).

clear_caps_cache(CapsNode) ->
    ok = ?RPC(mod_caps, delete_caps, [CapsNode]).

get_backend(Module) ->
  case ?RPC(Module, backend, []) of
    {badrpc, _Reason} -> false;
    Backend -> Backend
  end.

generic_count(mod_offline_backend, {User, Server}) ->
    ?RPC(mod_offline_backend, count_offline_messages, [User, Server, 100]).


generic_count(Module) ->
    case get_backend(Module) of
        false -> %% module disabled
            false;
        B when is_atom(B) ->
            generic_count_backend(B)
    end.

generic_count_backend(mod_offline_mnesia) -> count_wildpattern(offline_msg);
generic_count_backend(mod_offline_odbc) -> count_odbc(<<"offline_message">>);
generic_count_backend(mod_offline_riak) -> count_riak(<<"offline">>);
generic_count_backend(mod_last_mnesia) -> count_wildpattern(last_activity);
generic_count_backend(mod_last_odbc) -> count_odbc(<<"last">>);
generic_count_backend(mod_last_riak) -> count_riak(<<"last">>);
generic_count_backend(mod_privacy_mnesia) -> count_wildpattern(privacy);
generic_count_backend(mod_privacy_odbc) -> count_odbc(<<"privacy_list">>);
generic_count_backend(mod_privacy_riak) -> count_riak(<<"privacy_lists">>);
generic_count_backend(mod_private_mnesia) -> count_wildpattern(private_storage);
generic_count_backend(mod_private_odbc) -> count_odbc(<<"private_storage">>);
generic_count_backend(mod_private_mysql) -> count_odbc(<<"private_storage">>);
generic_count_backend(mod_private_riak) -> count_riak(<<"private">>);
generic_count_backend(mod_vcard_mnesia) -> count_wildpattern(vcard);
generic_count_backend(mod_vcard_odbc) -> count_odbc(<<"vcard">>);
generic_count_backend(mod_vcard_riak) -> count_riak(<<"vcard">>);
generic_count_backend(mod_vcard_ldap) ->
    D = ct:get_config({hosts, mim, domain}),
    %% number of vcards in ldap is the same as number of users
    ?RPC(ejabberd_auth_ldap, get_vh_registered_users_number, [D]);
generic_count_backend(mod_roster_mnesia) -> count_wildpattern(roster);
generic_count_backend(mod_roster_riak) ->
    count_riak(<<"rosters">>),
    count_riak(<<"roster_versions">>);
generic_count_backend(mod_roster_odbc) -> count_odbc(<<"rosterusers">>).

count_wildpattern(Table) ->
    Pattern = ?RPC(mnesia, table_info, [Table, wild_pattern]),
    length(?RPC(mnesia, dirty_match_object, [Pattern])).


count_odbc(Table) ->
    {selected, [{N}]} =
        ?RPC(mongoose_rdbms,sql_query, [<<"localhost">>,[<<"select count(*) from ", Table/binary, " ;">>]]),
    count_to_integer(N).

count_to_integer(N) when is_binary(N) ->
    list_to_integer(binary_to_list(N));
count_to_integer(N) when is_integer(N)->
    N.

count_riak(BucketType) ->
    {ok, Buckets} = ?RPC(mongoose_riak, list_buckets, [BucketType]),
    BucketKeys = [?RPC(mongoose_riak, list_keys, [{BucketType, Bucket}]) || Bucket <- Buckets],
    length(lists:flatten(BucketKeys)).

kick_everyone() ->
    [?RPC(ejabberd_c2s, stop, [Pid]) || Pid <- get_session_pids()],
    asset_session_count(0, 50).

asset_session_count(Expected, Retries) ->
    case wait_for_session_count(Expected, Retries) of
        Expected ->
            ok;
        Other ->
            ct:fail({asset_session_count, {expected, Expected}, {value, Other}})
    end.

wait_for_session_count(Expected, Retries) ->
    case length(get_session_specs()) of
        Expected ->
            Expected;
        _Other when Retries > 0 ->
            timer:sleep(100),
            wait_for_session_count(Expected, Retries-1);
        Other ->
            Other
    end.

get_session_specs() ->
    ?RPC(supervisor, which_children, [ejabberd_c2s_sup]).

get_session_pids() ->
    [element(2, X) || X <- get_session_specs()].


ensure_muc_clean() ->
    stop_online_rooms(),
    forget_persistent_rooms().

stop_online_rooms() ->
    Host = ct:get_config({hosts, mim, domain}),
    Supervisor = escalus_ejabberd:rpc(gen_mod, get_module_proc,
                                      [Host, ejabberd_mod_muc_sup]),
    escalus_ejabberd:rpc(erlang, exit, [Supervisor, kill]),
    escalus_ejabberd:rpc(mnesia, clear_table, [muc_online_room]),
    ok.

forget_persistent_rooms() ->
    escalus_ejabberd:rpc(mnesia, clear_table, [muc_room]),
    escalus_ejabberd:rpc(mnesia, clear_table, [muc_registered]),
    ok.

-spec successful_rpc(atom(), atom(), list()) -> term().
successful_rpc(Module, Function, Args) ->
    case escalus_ejabberd:rpc(Module, Function, Args) of
        {badrpc, Reason} ->
            ct:fail({badrpc, Module, Function, Args, Reason});
        Result ->
            Result
    end.

%% This function is a version of escalus_client:stop/2
%% that ensures that c2s process is dead.
%% This allows to avoid race conditions.
logout_user(Config, User) ->
    Resource = escalus_client:resource(User),
    Username = escalus_client:username(User),
    Server = escalus_client:server(User),
    Result = successful_rpc(ejabberd_sm, get_session_pid,
                            [Username, Server, Resource]),
    case Result of
        none ->
            %% This case can be a side effect of some error, you should
            %% check your test when you see the message.
            ct:pal("issue=user_not_registered jid=~ts@~ts/~ts",
                   [Username, Server, Resource]),
            escalus_client:stop(Config, User);
        Pid when is_pid(Pid) ->
            MonitorRef = erlang:monitor(process, Pid),
            escalus_client:stop(Config, User),
            %% Wait for pid to die
            receive
                {'DOWN', MonitorRef, _, _, _} ->
                    ok
                after 10000 ->
                    ct:pal("issue=c2s_still_alive "
                            "jid=~ts@~ts/~ts pid=~p",
                           [Username, Server, Resource, Pid]),
                    ct:fail({logout_user_failed, {Username, Resource, Pid}})
            end
    end.


connect_component(Component) ->
    connect_component(Component, component_start_stream).

connect_component(ComponentOpts, StartStep) ->
    Res = escalus_connection:start(ComponentOpts,
                                   [{?MODULE, StartStep},
                                    {?MODULE, component_handshake}]),
    case Res of
        {ok, Component, _} ->
            {component, ComponentName} = lists:keyfind(component, 1, ComponentOpts),
            {server, ComponentServer} = lists:keyfind(server, 1, ComponentOpts),
            ComponentAddr = <<ComponentName/binary, ".", ComponentServer/binary>>,
            {Component, ComponentAddr, ComponentName};
        {error, E} ->
            throw(cook_connection_step_error(E))
    end.

disconnect_component(Component, Addr) ->
    disconnect_components([Component], Addr).

disconnect_components(Components, Addr) ->
    %% TODO replace 'kill' with 'stop' when server supports stream closing
    [escalus_connection:kill(Component) || Component <- Components],
    wait_until_disconnected(Addr, 1000).

wait_until_disconnected(Addr, Timeout) when Timeout =< 0 ->
    error({disconnect_timeout, Addr});
wait_until_disconnected(Addr, Timeout) ->
    case rpc(ejabberd_router, lookup_component, [Addr]) of
        [] -> ok;
        [_|_] ->
            ct:sleep(200),
            wait_until_disconnected(Addr, Timeout - 200)
    end.

rpc(M, F, A) ->
    Node = ct:get_config({hosts, mim, node}),
    Cookie = escalus_ct:get_config(ejabberd_cookie),
    escalus_ct:rpc_call(Node, M, F, A, 10000, Cookie).

cook_connection_step_error(E) ->
    {connection_step_failed, Step, Reason} = E,
    {StepDef, _, _} = Step,
    {EDef, _} = Reason,
    {EDef, StepDef}.

get_bjid(UserSpec) ->
    User = proplists:get_value(username, UserSpec),
    Server = proplists:get_value(server, UserSpec),
    <<User/binary,"@",Server/binary>>.

component_start_stream(Conn = #client{props = Props}, []) ->
    {server, Server} = lists:keyfind(server, 1, Props),
    {component, Component} = lists:keyfind(component, 1, Props),

    ComponentHost = <<Component/binary, ".", Server/binary>>,
    StreamStart = component_stream_start(ComponentHost, false),
    ok = escalus_connection:send(Conn, StreamStart),
    StreamStartRep = escalus_connection:get_stanza(Conn, wait_for_stream),

    #xmlstreamstart{attrs = Attrs} = StreamStartRep,
    Id = proplists:get_value(<<"id">>, Attrs),

    {Conn#client{props = [{sid, Id}|Props]}, []}.

component_stream_start(Component, IsSubdomain) ->
    Attrs1 = [{<<"to">>, Component},
              {<<"xmlns">>, <<"jabber:component:accept">>},
              {<<"xmlns:stream">>,
               <<"http://etherx.jabber.org/streams">>}],
    Attrs2 = case IsSubdomain of
                 false ->
                     Attrs1;
                 true ->
                     [{<<"is_subdomain">>, <<"true">>}|Attrs1]
             end,
    #xmlstreamstart{name = <<"stream:stream">>, attrs = Attrs2}.

component_handshake(Conn = #client{props = Props}, []) ->
    {password, Password} = lists:keyfind(password, 1, Props),
    {sid, SID} = lists:keyfind(sid, 1, Props),

    Handshake = component_handshake_el(SID, Password),
    ok = escalus_connection:send(Conn, Handshake),

    HandshakeRep = escalus_connection:get_stanza(Conn, handshake),
    case HandshakeRep of
        #xmlel{name = <<"handshake">>, children = []} ->
            {Conn, []};
        #xmlel{name = <<"stream:error">>} ->
            throw({stream_error, HandshakeRep})
    end.

component_handshake_el(SID, Password) ->
    Handshake = crypto:hash(sha, <<SID/binary, Password/binary>>),
    #xmlel{name = <<"handshake">>,
           children = [#xmlcdata{content = base16:encode(Handshake)}]}.
