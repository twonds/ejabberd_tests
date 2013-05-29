-module(configurations_CTH).

-export([init/2,
         pre_init_per_suite/3,
         post_end_per_suite/4]).

-record(state, {configs, first, last, current, node, config_file,
                template, default}).

init(_Id, [Suites, Configs, Node]) ->
    [First|_] = Suites,
    [Last|_] = lists:reverse(Suites),
    {ok, Cwd} = call(Node, file, get_cwd, []),
    Cfg = filename:join([Cwd, "..", "..", "rel", "files", "ejabberd.cfg"]),
    Vars = filename:join([Cwd, "..", "..", "rel", "reltool_vars", "node1_vars.config"]),
    CfgFile = filename:join([Cwd, "etc", "ejabberd.cfg"]),
    {ok, Template} = call(Node, file, read_file, [Cfg]),
    {ok, Default} = call(Node, file, consult, [Vars]),
    {ok, #state{configs=Configs,
                first=First,
                last=Last,
                node=Node,
                config_file=CfgFile,
                template=Template,
                default=Default}}.

pre_init_per_suite(Suite, Config,
                   #state{first=Suite,
                          node=Node,
                          config_file=CfgFile,
                          template=Template,
                          default=Default,
                          configs=[{Current,Vars}|Rest]}=State) ->
    NewVars = lists:foldl(fun({Var,Val}, Acc) ->
                    lists:keystore(Var, 1, Acc, {Var,Val})
            end, Default, Vars), 
    LTemplate = binary_to_list(Template),
    NewCfgFile = mustache:render(LTemplate, dict:from_list(NewVars)),
    ok = call(Node, file, write_file, [CfgFile, NewCfgFile]),
    ok = call(Node, application, stop, [ejabberd]),
    ok = call(Node, application, start, [ejabberd]),
    error_logger:info_msg("Configuration ~p test started.~n", [Current]),
    NewConfig = lists:keystore(current_config, 1, Config, {current_config, Current}),
    {NewConfig, State#state{current=Current, configs=Rest}};
pre_init_per_suite(_Suite, Config, State) ->
    {Config, State}.

post_end_per_suite(Suite, _Config, Return,
                   #state{current=Current,
                          last=Suite}=State) ->
    error_logger:info_msg("Configuration ~p test finished.~n", [Current]),
    {Return, State};
post_end_per_suite(_Suite, _Config, Return, State) ->
    {Return, State}.

call(Node, M, F, A) ->
    rpc:call(Node, M, F, A).
