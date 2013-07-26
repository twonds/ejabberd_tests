%%==============================================================================
%% Copyright 2013 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================
-module(ejabberdctl_SUITE).
-compile(export_all).

-include_lib("escalus/include/escalus.hrl").
-include_lib("common_test/include/ct.hrl").

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [{group, accounts}].

groups() ->
     [{accounts, [sequence], accounts()}].

accounts() -> [change_password, check_password_hash, check_password,
               check_account, ban_account, num_active_users, delete_old_users,
               delete_old_users_vhost].

suite() ->
    escalus:suite().

init_per_suite(Config) ->
    {ok, EjdWD} = escalus_ejabberd:rpc(file, get_cwd, []),
    start_mod_admin_extra(),
    NewConfig = escalus:init_per_suite([{ctl_path, EjdWD ++ "/bin/ejabberdctl"} | Config]),
    escalus:create_users(NewConfig).

end_per_suite(Config) ->
    delete_users(Config),
    escalus:end_per_suite(Config).

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, Config) ->
    Config.

init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(delete_old_users, Config) ->
    Users = escalus_users:get_users(all),
    lists:foreach(fun({_User, UserSpec}) ->
                {Username, Domain, Pass} = get_user_data(UserSpec, Config),
                escalus_ejabberd:rpc(ejabberd_auth, try_register, [Username, Domain, Pass])
        end, Users),
    escalus_cleaner:clean(),
    escalus:end_per_testcase(delete_old_users, Config);
end_per_testcase(CaseName, Config) ->
    escalus_cleaner:clean(),
    escalus:end_per_testcase(CaseName, Config).

%%--------------------------------------------------------------------
%% mod_admin_extra_accounts tests
%%--------------------------------------------------------------------

change_password(Config) ->
    {User, Domain, OldPassword} = get_user_data(alice, Config),
    ejabberdctl("change_password", [User, Domain, <<OldPassword/binary, $2>>], Config),
    {error, {connection_step_failed, _, _}} = escalus_client:start_for(Config, alice, <<"newres">>),
    ejabberdctl("change_password", [User, Domain, OldPassword], Config),
    {ok, _Alice2} = escalus_client:start_for(Config, alice, <<"newres2">>).

check_password_hash(Config) ->
    {User, Domain, Pass} = get_user_data(alice, Config),
    MD5Hash = get_md5(Pass),
    MD5HashBad = get_md5(<<Pass/binary, "bad">>),
    SHAHash = get_sha(Pass),

    {_, 0} = ejabberdctl("check_password_hash", [User, Domain, MD5Hash, "md5"], Config),
    {_, ErrCode} = ejabberdctl("check_password_hash", [User, Domain, MD5HashBad, "md5"], Config),
    true = (ErrCode =/= 0), %% Must return code other than 0
    {_, 0} = ejabberdctl("check_password_hash", [User, Domain, SHAHash, "sha"], Config).

check_password(Config) ->
    {User, Domain, Pass} = get_user_data(alice, Config),

    {_, 0} = ejabberdctl("check_password", [User, Domain, Pass], Config),
    {_, ErrCode} = ejabberdctl("check_password", [User, Domain, <<Pass/binary, "Bad">>], Config),
    true = (ErrCode =/= 0). %% Must return code other than 0

check_account(Config) ->
    {User, Domain, _Pass} = get_user_data(alice, Config),

    {_, 0} = ejabberdctl("check_account", [User, Domain], Config),
    {_, ErrCode} = ejabberdctl("check_account", [<<User/binary, "Bad">>, Domain], Config),
    true = (ErrCode =/= 0). %% Must return code other than 0

ban_account(Config) ->
    {User, Domain, Pass} = get_user_data(mike, Config),

    {ok, Mike} = escalus_client:start_for(Config, mike, <<"newres">>),
    {_, 0} = ejabberdctl("ban_account", [User, Domain, "SomeReason"], Config),
    {'EXIT', _} = (catch escalus_client:send(Mike,
                                                 escalus_stanza:chat_to(Mike, <<"Hello myself!">>))),
    {error, {connection_step_failed, _, _}} = escalus_client:start_for(Config, mike, <<"newres2">>),
    ejabberdctl("change_password", [User, Domain, Pass], Config).

num_active_users(Config) ->
    {AliceName, Domain, _} = get_user_data(alice, Config),
    {MikeName, Domain, _} = get_user_data(mike, Config),
    
    {Mega, Secs, _} = erlang:now(),
    Now = Mega*1000000+Secs,
    set_last(AliceName, Domain, Now),
    set_last(MikeName, Domain, Now - 864000), %% Now - 10 days

    {"1\n", _} = ejabberdctl("num_active_users", [Domain, "5"], Config).

delete_old_users(Config) ->
    {AliceName, Domain, _} = get_user_data(alice, Config),
    {BobName, Domain, _} = get_user_data(bob, Config),
    {KateName, Domain, _} = get_user_data(kate, Config),
    {MikeName, Domain, _} = get_user_data(mike, Config),
    
    {Mega, Secs, _} = erlang:now(),
    Now = Mega*1000000+Secs,
    set_last(AliceName, Domain, Now),
    set_last(BobName, Domain, Now),
    set_last(MikeName, Domain, Now),

    {_, 0} = ejabberdctl("delete_old_users", ["10"], Config),
    {_, 0} = ejabberdctl("check_account", [AliceName, Domain], Config),
    {_, ErrCode} = ejabberdctl("check_account", [KateName, Domain], Config),
    true = (ErrCode =/= 0). %% Must return code other than 0

delete_old_users_vhost(Config) ->
    {AliceName, Domain, _} = get_user_data(alice, Config),
    {KateName, Domain, KatePass} = get_user_data(kate, Config),
    SecDomain = escalus_config:get_config(ejabberd_secondary_domain, Config),
    
    {Mega, Secs, _} = erlang:now(),
    Now = Mega*1000000+Secs,
    set_last(AliceName, Domain, Now-86400*30),

    {_, 0} = ejabberdctl("register", [KateName, SecDomain, KatePass], Config),
    {_, 0} = ejabberdctl("check_account", [KateName, SecDomain], Config),
    {_, 0} = ejabberdctl("delete_old_users_vhost", [SecDomain, "10"], Config),
    {_, 0} = ejabberdctl("check_account", [AliceName, Domain], Config),
    {_, ErrCode} = ejabberdctl("check_account", [KateName, SecDomain], Config),
    true = (ErrCode =/= 0). %% Must return code other than 0


%%--------------------------------------------------------------------
%% Last tests
%%--------------------------------------------------------------------
last_online_user(Config) ->
    escalus:story(Config, [1, 1],
                  fun(_Alice, _Bob) ->
                ok
                  end).

%%-----------------------------------------------------------------
%% Helpers
%%-----------------------------------------------------------------

start_mod_admin_extra() ->
    Domain = ct:get_config(ejabberd_domain),
    ok = dynamic_modules:restart(Domain, mod_admin_extra, []).

normalize_args(Args) ->
    lists:map(fun
            (Arg) when is_binary(Arg) ->
                binary_to_list(Arg);
            (Arg) when is_list(Arg) ->
                Arg
        end, Args).

ejabberdctl(Cmd, Args, Config) ->
    CtlCmd = escalus_config:get_config(ctl_path, Config),
    run(string:join([CtlCmd, Cmd | normalize_args(Args)], " ")).

get_user_data(User, Config) when is_atom(User) ->
    get_user_data(escalus_users:get_options(Config, User, <<"newres">>), Config);
get_user_data(User, _Config) ->
    {_, Password} = lists:keyfind(password, 1, User),
    {_, Username} = lists:keyfind(username, 1, User),
    {_, Domain} = lists:keyfind(server, 1, User),
    {Username, Domain, Password}.

run(Cmd) -> 
    run(Cmd, 5000).

run(Cmd, Timeout) ->
    Port = erlang:open_port({spawn, Cmd},[exit_status]),
    loop(Port,[], Timeout).

loop(Port, Data, Timeout) ->
    receive
        {Port, {data, NewData}} -> loop(Port, Data++NewData, Timeout);
        {Port, {exit_status, ExitStatus}} -> {Data, ExitStatus}
    after Timeout ->
            throw(timeout)
    end.

get_md5(AccountPass) ->
    lists:flatten([io_lib:format("~.16B", [X])
                   || X <- binary_to_list(crypto:md5(AccountPass))]).
get_sha(AccountPass) ->
    lists:flatten([io_lib:format("~.16B", [X])
                   || X <- binary_to_list(crypto:sha(AccountPass))]).

set_last(User, Domain, TStamp) ->
    Mod = escalus_ejabberd:rpc(mod_admin_extra_last, get_lastactivity_module, [Domain]),
    escalus_ejabberd:rpc(Mod, store_last_info, [User, Domain, TStamp, <<>>]).

delete_users(Config) ->
    Users = escalus_users:get_users(all),
    lists:foreach(fun({_User, UserSpec}) ->
                {Username, Domain, _Pass} = get_user_data(UserSpec, Config),
                escalus_ejabberd:rpc(ejabberd_auth, remove_user, [Username, Domain])
        end, Users).