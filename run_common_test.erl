-module(run_common_test).
-export([ct/0, ct_cover/0, cover_summary/0]).

-define(CT_DIR, filename:join([".", "tests"])).
-define(CT_REPORT, filename:join([".", "ct_report"])).

ct_config_file() ->
    {ok, CWD} = file:get_cwd(),
    filename:join([CWD, "test.config"]).

ct_vcard_config_file() ->
    {ok, CWD} = file:get_cwd(),
    filename:join([CWD, "vcard.config"]).


tests_to_run() ->
    [{suite, [
            adhoc_SUITE,
            anonymous_SUITE,
            last_SUITE,
            login_SUITE,
            muc_SUITE,
            offline_SUITE,
            presence_SUITE,
            privacy_SUITE,
            private_SUITE,
            s2s_SUITE,
            sic_SUITE,
            %snmp_SUITE,
            %snmp_c2s_SUITE,
            %snmp_register_SUITE,
            %snmp_roster_SUITE,
            %snmp_session_SUITE,
            %snmp_table_SUITE,
            vcard_SUITE,
            websockets_SUITE,
            metrics_c2s_SUITE,
            metrics_roster_SUITE,
            metrics_register_SUITE,
            metrics_session_SUITE,
            system_monitor_SUITE
            ]}].

    %[{suite, muc_SUITE},
     %{group, admin},
     %{testcase, admin_moderator},
     %{repeat, 4}].

ct() ->
    Result = ct:run_test(prepare_tests()),
    case Result of
        {error, Reason} ->
            throw({ct_error, Reason});
        _ ->
            ok
    end,
    save_count(),
    init:stop(0).

ct_cover() ->
    run_ct_cover(),
    cover_summary(),
    save_count(),
    init:stop(0).

save_count() ->
    Count = try
        [{count, N}] = ets:lookup(configurations_CTH, count),
        N
    catch _:_ ->
        1
    end,
    file:write_file("/tmp/ct_count", integer_to_list(Count)).

prepare_tests() ->
    {ok, Props} = file:consult(ct_config_file()),
    Tests = tests_to_run(),
    Suites = proplists:get_value(suite, Tests, []),
    Spec1 = [{config, [ct_config_file(), ct_vcard_config_file()]},
             {dir, ?CT_DIR},
             {logdir, ?CT_REPORT},
             {suite, Suites}
            ],
    Spec2 = case proplists:lookup(ejabberd_configs, Props) of
        {ejabberd_configs, Configs} ->
            ets:new(configurations_CTH, [public, named_table,
                                         {read_concurrency, true}]),
            ets:insert(configurations_CTH, {count, 0}),
            Interval = proplists:get_value(repeat, Tests, 1),
            [{repeat, length(Configs)*Interval},
             {ct_hooks, 
              [{configurations_CTH, [Configs, get_ejabberd_node(), Interval]}]}
             | Spec1];
        _ ->
            Spec1
    end,
    Spec2 ++ Tests.

run_ct_cover() ->
    prepare(),
    ct:run_test(tests_to_run()),
    N = get_ejabberd_node(),
    Files = rpc:call(N, filelib, wildcard, ["/tmp/ejd_test_run_*.coverdata"]),
    [rpc:call(N, file, delete, [File]) || File <- Files],
    {MS,S,_} = now(),
    FileName = lists:flatten(io_lib:format("/tmp/ejd_test_run_~b~b.coverdata",[MS,S])),
    io:format("export current cover ~p~n", [cover_call(export, [FileName])]),
    io:format("test finished~n").

cover_summary() ->
    prepare(),
    Files = rpc:call(get_ejabberd_node(), filelib, wildcard, ["/tmp/ejd_test_run_*.coverdata"]),
    lists:foreach(fun(F) ->
                          io:format("import ~p cover ~p~n", [F, cover_call(import, [F])])
                  end,
                  Files),
    analyze(summary),
    io:format("summary completed~n"),
    init:stop(0).

prepare() ->
    cover_call(start),
    Compiled = cover_call(compile_beam_directory,["lib/ejabberd-2.1.8/ebin"]),
    rpc:call(get_ejabberd_node(), application, stop, [ejabberd]),
    StartStatus = rpc:call(get_ejabberd_node(), application, start, [ejabberd, permanent]),
    io:format("start ~p~n", [StartStatus]),
    io:format("Compiled modules ~p~n", [Compiled]).
    %%timer:sleep(10000).

analyze(Node) ->
    Modules = cover_call(modules),
    io:format("node ~s~n", [Node]),
    FilePath = case {Node, file:read_file(?CT_REPORT++"/index.html")} of
        {summary, {ok, IndexFileData}} ->
            R = re:replace(IndexFileData, "<a href=\"all_runs.html\">ALL RUNS</a>", "& <a href=\"cover.html\" style=\"margin-right:5px\">COVER</a>"),
            file:write_file(?CT_REPORT++"/index.html", R),
            ?CT_REPORT++"/cover.html";
        _ -> skip
    end,
    CoverageDir = filename:dirname(FilePath)++"/coverage",
    rpc:call(get_ejabberd_node(), file, make_dir, ["/tmp/coverage"]),
    {ok, File} = file:open(FilePath, [write]),
    file:write(File, "<html>\n<head></head>\n<body bgcolor=\"white\" text=\"black\" link=\"blue\" vlink=\"purple\" alink=\"red\">\n"),
    file:write(File, "<h1>Coverage for application 'esl-ejabberd'</h1>\n"),
    file:write(File, "<table border=3 cellpadding=5>\n"),
    file:write(File, "<tr><th>Module</th><th>Covered (%)</th><th>Covered (Lines)</th><th>Not covered (Lines)</th><th>Total (Lines)</th></tr>"),
    Fun = fun(Module, {CAcc, NCAcc}) ->
                  FileName = lists:flatten(io_lib:format("~s.COVER.html",[Module])),
                  FilePathC = filename:join(["/tmp/coverage", FileName]),
                  io:format("Analysing module ~s~n", [Module]),
                  cover_call(analyse_to_file, [Module, FilePathC, [html]]),
                  {ok, {Module, {C, NC}}} = cover_call(analyse, [Module, module]),
                  file:write(File, row(atom_to_list(Module), C, NC, percent(C,NC),"coverage/"++FileName)),
                  {CAcc + C, NCAcc + NC}
          end,
    io:format("coverage analyzing~n"),
    {CSum, NCSum} = lists:foldl(Fun, {0, 0}, Modules),
    os:cmd("cp -R /tmp/coverage "++CoverageDir),
    file:write(File, row("Summary", CSum, NCSum, percent(CSum, NCSum), "#")),
    file:close(File).

cover_call(Function) ->
    cover_call(Function, []).

cover_call(Function, Args) ->
    rpc:call(get_ejabberd_node(), cover, Function, Args).

get_ejabberd_node() ->
    {ok, Props} = file:consult(ct_config_file()),
    {ejabberd_node, Node} = proplists:lookup(ejabberd_node, Props),
    Node.

percent(0, _) -> 0;
percent(C, NC) when C /= 0; NC /= 0 -> round(C / (NC+C) * 100);
percent(_, _)                       -> 100.

row(Row, C, NC, Percent, Path) ->
    [
        "<tr>",
        "<td><a href='", Path, "'>", Row, "</a></td>",
        "<td>", integer_to_list(Percent), "%</td>",
        "<td>", integer_to_list(C), "</td>",
        "<td>", integer_to_list(NC), "</td>",
        "<td>", integer_to_list(C+NC), "</td>",
        "</tr>\n"
    ].
