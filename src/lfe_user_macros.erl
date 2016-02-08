%% Copyright (c) 2016 Robert Virding
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

%% File    : lfe_user_macros.erl
%% Author  : Robert Virding
%% Purpose : Lisp Flavoured Erlang user macro function builder.

%% Build the LFE-EXPAND-USER-MACRO function which exports macros so
%% they can be found by the macro expander without needing to inlcude
%% them. If the module foo exports macro bar then it can be called by
%% doing (foo:bar ...).
%%
%% This version expands the macros when the defining module is
%% compiled so they are expanded in the context when that module is
%% compiled, not when they are called. This is easy and makes it easy
%% to access all macros in the defining module.
%%
%% An alternative would be to expand the macros when they are called
%% but then it becomes difficult to access all the macros within the
%% defining module. This might be easy if we accept exporting all
%% macros not just specific ones.
%%
%% The matching is done in two steps: first we test whether the call
%% name is one of our known macros; if so we test whether the
%% arguments match against the argument patterns in the macro
%% definition. Doing it like this gives us the same failure handling
%% as when expanding local calls to macros.

%% (defun LFE-EXPAND-USER-MACRO (name args $ENV)
%%   (let ((var-1 val-1)                   ;Eval-when-compile variables
%%         ...)
%%     (fletrec ((fun-1 ...)               ;Eval-when-compile functions
%%               ...)
%%       (case name                        ;Macro name without module
%%         ('mac-1 ...)                    ;Already exported local macros
%%          (case args                     ;Match against args
%%           (arg-pat ...)
%%           ...))
%%         ('mac-2 ...)
%%         ...
%%         (_ 'no)))))

-module(lfe_user_macros).

%%-compile(export_all).

-include("lfe_comp.hrl").

-export([module/2]).

-import(lists, [reverse/1,reverse/2,member/2,filter/2]).

%% We do a lot of quoting!
-define(Q(E), [quote,E]).
-define(BQ(E), [backquote,E]).
-define(C(E), [comma,E]).
-define(C_A(E), ['comma-at',E]).

-record(umac, {mline=[],expm=[],env=[]}).

%% We need these variables to have a funny name.
-define(NAMEVAR, '|- MACRO NAME -|').
-define(ARGSVAR, '|- CALL ARGS -|').

%% module(ModuleForms, CompState) -> {ModuleForms,CompState}.
%% module(ModuleDef, ModuleForms, UmacState, CompState) ->
%%     {ModuleForms,CompState}.

module([Mdef|Fs], Cst) ->
    Mst = collect_macros(Fs, #umac{env=lfe_env:new()}),
    %% io:format("m: ~p\n", [Umac]),
    module(Mdef, Fs, Mst, Cst).

module({['define-module',Name|Mdef],L}, Fs, Mst0, Cst) ->
    Mst1 = collect_mdef(Mdef, Mst0#umac{mline=L}),
    Umac = build_user_macro(Mst1),
    %% We need to export the expansion function but leave the rest.
    Md1 = {['define-module',Name,[export,['LFE-EXPAND-USER-MACRO',3]]|Mdef],L},
    {[Md1|Fs ++ [{Umac,L}]],Cst}.

collect_macros(Fs, Mst) ->
    lists:foldl(fun collect_macro/2, Mst, Fs).

collect_macro({['define-macro',Name,Def],_}, #umac{env=Env0}=Mst) ->
    Env1 = lfe_env:add_mbinding(Name, Def, Env0),
    Mst#umac{env=Env1};
collect_macro({['eval-when-compile'|Fs],_}, Mst) ->
    lists:foldl(fun collect_ewc_macro/2, Mst, Fs);
collect_macro({['extend-module'|Mdef],_}, Mst) ->
    collect_mdef(Mdef, Mst);
collect_macro(_, Mst) -> Mst.

collect_ewc_macro([set,Name,Val], #umac{env=Env0}=Mst) ->
    Env1 = lfe_env:add_vbinding(Name, Val, Env0),
    Mst#umac{env=Env1};
collect_ewc_macro(['define-function',Name,Def], #umac{env=Env0}=Mst) ->
    Ar = function_arity(Def),
    Env1 = lfe_env:add_fbinding(Name, Ar, Def, Env0),
    Mst#umac{env=Env1};
collect_ewc_macro([progn|Fs], Mst) ->
    lists:foldl(fun collect_ewc_macro/2, Mst, Fs).

function_arity([lambda,As|_]) -> length(As);
function_arity(['match-lambda',[Pats|_]|_]) -> length(Pats).

%% collect_mdef(ModuleDef, MacroState) -> MacroState.
%%  We are only interested in which macros are exported.

collect_mdef([['export-macro'|Ms]|Mdef], #umac{expm=Expm0}=Mst) ->
    Expm1 = add_exports(Expm0, Ms),
    collect_mdef(Mdef, Mst#umac{expm=Expm1});
collect_mdef([_|Mdef], Mst) -> collect_mdef(Mdef, Mst);
collect_mdef([], Mst) -> Mst.

%% add_exports(Old, More) -> New.
%% exported_macro(Name, State) -> true | false.

add_exports(all, _) -> all;
add_exports(_, all) -> all;
add_exports(Old, More) ->
    ordsets:union(Old, lists:usort(More)).

exported_macro(_, #umac{expm=all}) -> true;     %All are exported
exported_macro(Name, #umac{expm=Expm}) ->
    member(Name, Expm).

%% build_user_macro(MacroState) -> UserMacFunc.
%%  Take the forms in the eval-when-compile and build the
%%  LFE-EXPAND-USER-MACRO function. In this version we expand the
%%  macros are compile time.

build_user_macro(#umac{expm=[]}) ->             %No macros to export
    empty_leum();
build_user_macro(#umac{env=Env}=Mst) ->
    Vfun = fun (N, V, Acc) -> [[N,V]|Acc] end,
    Sets = lfe_env:fold_vars(Vfun, [], Env),
    %% Collect the local functions.
    Ffun = fun (N, _, Def, Acc) ->
                   %% [[N,lfe_macro:expand_expr_all(Def, Env)]|Acc]
                   [[N,Def]|Acc]
           end,
    Funs = lfe_env:fold_funs(Ffun, [], Env),
    %% Collect the local macros.
    Mfun = fun (N, Def0, Acc) ->
                   case exported_macro(N, Mst) of
                       true ->
                           %% Def1 = lfe_macro:expand_expr_all(Def0, Env),
                           [macro_case_clause(N, Def0)|Acc];
                       false -> Acc
                   end
           end,
    %% Get the macros to export as case clauses.
    case lfe_env:fold_macros(Mfun, [], Env) of
        [] -> empty_leum();                     %No macros to export
        Macs ->
            %% Build case, flet and let.
            Case = ['case',?NAMEVAR|Macs ++ [['_',?Q(no)]]],
            Flr = ['letrec-function',Funs,Case],
            Fl = ['let',Sets,Flr],
            ['define-function','LFE-EXPAND-USER-MACRO',
	     [lambda,[?NAMEVAR,?ARGSVAR,'$ENV'],Fl]]
    end.

empty_leum() ->
    ['define-function','LFE-EXPAND-USER-MACRO',[lambda,['_','_','_'],?Q(no)]].

%% macro_case_clause(Name, Def) -> CaseClause.
%%  Build a case clause for expanding macr Name.

macro_case_clause(Name, Def) ->
    Cls = get_macro_cls(Def),
    Ccls = [ macro_clause(Args, B) || {Args,B} <- Cls ],
    [?Q(Name),['case',?ARGSVAR|Ccls]].          %Don't catch errors

%% get_macro_cls(MacroDef) -> [{ArgPat,Body}].
%%  Build a list of arg pattern and body for each clause. In the
%%  definition arguments the first is the argument pattern, the second
%%  is the environment variable $ENV. Be nice.

get_macro_cls(['lambda',[Arg|_]|B]) ->
    [{Arg,B}];                                  %Only one clause here
get_macro_cls(['match-lambda'|Cls]) ->
    [ {Arg,B} || [[Arg|_]|B] <- Cls ];
get_macro_cls(_) -> [].                         %Ignore bad formed macros

macro_clause(Args, Body) ->
    [Args,[tuple,?Q(yes),[progn|Body]]].
