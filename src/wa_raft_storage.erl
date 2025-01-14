%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.
%%%
%%% This module implements storage to apply group consensuses. The theory
%%% is that storage is an finite state machine. If we apply a sequence
%%% of changes in exactly same order on finite state machines, we get
%%% identical copies of finite state machines.
%%%
%%% A storage could be filesystem, ets, or any other local storage.
%%% Storage interface is defined as callbacks.

-module(wa_raft_storage).
-compile(warn_missing_spec).
-behaviour(gen_server).

%% OTP supervisor
-export([
    child_spec/1,
    start_link/1
]).

%% Read / Apply / Cancel operations.
-export([
    apply_op/3,
    fulfill_op/3,
    read/3,
    cancel/1
]).

%% API
-export([
    open/1,
    open_snapshot/2,
    create_snapshot/1,
    create_snapshot/2,
    delete_snapshot/2
]).

%% Cluster state API
-export([
    read_metadata/2
]).

%% Misc API
-export([
    status/1
]).

%% Internal API
-export([
    default_name/2,
    registered_name/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% Test API
-ifdef(TEST).
-export([
    reset/3
]).
-endif.

-export_type([
    storage_handle/0,
    metadata/0,
    error/0,
    status/0
]).

-include_lib("kernel/include/logger.hrl").
-include("wa_raft.hrl").

%% Storage plugin need implement the following mandatory callbacks to integrate with raft protocol.
%% Callback to open storage handle for operations
-callback storage_open(atom(), wa_raft:table(), wa_raft:partition(), file:filename()) -> storage_handle().
%% Callback to get current "position" of the storage FSM
-callback storage_position(storage_handle()) -> wa_raft_log:log_pos().
%% Callback to close storage handle
-callback storage_close(storage_handle()) -> term().
%% Callback to apply an update to storage
-callback storage_apply(wa_raft_acceptor:command(), wa_raft_log:log_pos(), storage_handle()) -> {eqwalizer:dynamic(), storage_handle()}.

%% Callback to create a snapshot for current storage state
-callback storage_create_snapshot(file:filename(), storage_handle()) -> ok | error().
%% Callback to open storage handle from a snapshot
-callback storage_open_snapshot(file:filename(), wa_raft_log:log_pos(), storage_handle()) -> {ok, storage_handle()} | wa_raft_storage:error().

%% Callback to get the status of the RAFT storage module
-callback storage_status(Handle :: storage_handle()) -> proplists:proplist().

%% Callback to write RAFT cluster state values
-callback storage_write_metadata(Handle :: storage_handle(), Key :: metadata(), Version :: wa_raft_log:log_pos(), Value :: term()) -> ok | error().
%% Callback to read RAFT cluster state values
-callback storage_read_metadata(Handle :: storage_handle(), Key :: metadata()) -> {ok, Version :: wa_raft_log:log_pos(), Value :: term()} | undefined | error().

-type metadata() :: config | atom().
-type storage_handle() :: eqwalizer:dynamic().
-type error() :: {error, term()}.

-type status() :: [status_element()].
-type status_element() ::
      {name, atom()}
    | {table, wa_raft:table()}
    | {partition, wa_raft:partition()}
    | {module, module()}
    | {last_applied, wa_raft_log:log_index()}
    | ModuleSpecificStatus :: {atom(), term()}.

%% Storage state
-record(state, {
    name :: atom(),
    table :: wa_raft:table(),
    partition :: wa_raft:partition(),
    root_dir :: file:filename(),
    module :: module(),
    handle :: storage_handle(),
    last_applied :: wa_raft_log:log_pos()
}).

-spec child_spec(Options :: #raft_options{}) -> supervisor:child_spec().
child_spec(Options) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Options]},
        restart => transient,
        shutdown => 30000,
        modules => [?MODULE]
    }.

%% Public API
-spec start_link(Options :: #raft_options{}) -> {'ok', Pid::pid()} | 'ignore' | {'error', Reason::term()}.
start_link(#raft_options{storage_name = Name} = Options) ->
    gen_server:start_link({local, Name}, ?MODULE, Options, []).

-spec status(ServiceRef :: pid() | atom()) -> status().
status(ServiceRef) ->
    gen_server:call(ServiceRef, status, ?RAFT_STORAGE_CALL_TIMEOUT()).

-spec apply_op(ServiceRef :: pid() | atom(), LogRecord :: wa_raft_log:log_record(), ServerTerm :: wa_raft_log:log_term()) -> ok.
apply_op(ServiceRef, LogRecord, ServerTerm) ->
    gen_server:cast(ServiceRef, {apply, LogRecord, ServerTerm}).

-spec fulfill_op(ServiceRef :: pid() | atom(), Reference :: term(), Reply :: term()) -> ok.
fulfill_op(ServiceRef, OpRef, Return) ->
    gen_server:cast(ServiceRef, {fulfill, OpRef, Return}).

-spec read(ServiceRef :: pid() | atom(), From :: gen_server:from(), Op :: wa_raft_acceptor:command()) -> ok.
read(ServiceRef, From, Op) ->
    gen_server:cast(ServiceRef, {read, From, Op}).

-spec cancel(ServiceRef :: pid() | atom()) -> ok.
cancel(ServiceRef) ->
    gen_server:cast(ServiceRef, cancel).

-spec open(ServiceRef :: pid() | atom()) -> {ok, LastApplied :: wa_raft_log:log_pos()}.
open(ServiceRef) ->
    gen_server:call(ServiceRef, open, ?RAFT_RPC_CALL_TIMEOUT()).

-spec open_snapshot(ServiceRef :: pid() | atom(), LastAppliedPos :: wa_raft_log:log_pos()) -> ok | error().
open_snapshot(ServiceRef, LastAppliedPos) ->
    gen_server:call(ServiceRef, {snapshot_open, LastAppliedPos}, ?RAFT_STORAGE_CALL_TIMEOUT()).

-spec create_snapshot(ServiceRef :: pid() | atom()) -> {ok, Pos :: wa_raft_log:log_pos()} | error().
create_snapshot(ServiceRef) ->
    gen_server:call(ServiceRef, snapshot_create, ?RAFT_STORAGE_CALL_TIMEOUT()).

-spec create_snapshot(ServiceRef :: pid() | atom(), Name :: string()) -> ok | error().
create_snapshot(ServiceRef, Name) ->
    gen_server:call(ServiceRef, {snapshot_create, Name}, ?RAFT_STORAGE_CALL_TIMEOUT()).

-spec delete_snapshot(ServiceRef :: pid() | atom(), Name :: string()) -> ok.
delete_snapshot(ServiceRef, Name) ->
    gen_server:cast(ServiceRef, {snapshot_delete, Name}).

-spec read_metadata(ServiceRef :: pid() | atom(), Key :: metadata()) -> {ok, Version :: wa_raft_log:log_pos(), Value :: eqwalizer:dynamic()} | undefined | error().
read_metadata(ServiceRef, Key) ->
    gen_server:call(ServiceRef, {read_metadata, Key}, ?RAFT_STORAGE_CALL_TIMEOUT()).

-ifdef(TEST).
-spec reset(ServiceRef :: pid() | atom(), Position :: wa_raft_log:log_pos(), Config :: wa_raft_server:config() | undefined) -> ok | error().
reset(ServiceRef, Position, Config) ->
    sys:replace_state(ServiceRef, fun (#state{module = Module, handle = Handle} = State) ->
        Config =/= undefined andalso
            Module:storage_write_metadata(Handle, config, Position, Config),
        State#state{last_applied = Position}
    end, ?RAFT_STORAGE_CALL_TIMEOUT()),
    ok.
-endif.

%%-------------------------------------------------------------------
%% Internal API
%%-------------------------------------------------------------------

%% Get the default name for the RAFT storage server associated with the
%% provided RAFT partition.
-spec default_name(Table :: wa_raft:table(), Partition :: wa_raft:partition()) -> Name :: atom().
default_name(Table, Partition) ->
    list_to_atom("raft_storage_" ++ atom_to_list(Table) ++ "_" ++ integer_to_list(Partition)).

%% Get the registered name for the RAFT storage server associated with the
%% provided RAFT partition or the default name if no registration exists.
-spec registered_name(Table :: wa_raft:table(), Partition :: wa_raft:partition()) -> Name :: atom().
registered_name(Table, Partition) ->
    case wa_raft_part_sup:options(Table, Partition) of
        undefined -> default_name(Table, Partition);
        Options   -> Options#raft_options.storage_name
    end.

%% gen_server callbacks
-spec init(Options :: #raft_options{}) -> {ok, #state{}}.
init(#raft_options{table = Table, partition = Partition, database = RootDir, storage_name = Name, storage_module = Module}) ->
    process_flag(trap_exit, true),

    ?LOG_NOTICE("Storage[~0p] starting for partition ~0p/~0p at ~0p using ~0p",
        [Name, Table, Partition, RootDir, Module], #{domain => [whatsapp, wa_raft]}),

    Handle = Module:storage_open(Name, Table, Partition, RootDir),
    LastApplied = Module:storage_position(Handle),

    ?LOG_NOTICE("Storage[~0p] opened at position ~0p.",
        [Name, LastApplied], #{domain => [whatsapp, wa_raft]}),

    {ok, #state{
        name = Name,
        table = Table,
        partition = Partition,
        root_dir = RootDir,
        module = Module,
        handle = Handle,
        last_applied = LastApplied
    }}.

%% The interaction between the RAFT server and the RAFT storage server is designed to be
%% as asynchronous as possible since the RAFT storage server may be caught up in handling
%% a long running I/O request while it is working on applying new log entries.
%% If you are adding a new call to the RAFT storage server, make sure that it is either
%% guaranteed to not be used when the storage server is busy (and may not reply in time)
%% or timeouts and other failures are handled properly.
-spec handle_call(Request, From :: gen_server:from(), State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {noreply, NewState :: #state{}} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}}
    when Request ::
        open |
        snapshot_create |
        {snapshot_create, Name :: string()} |
        {snapshot_open, LastAppliedPos :: wa_raft_log:log_pos()} |
        {read_metadata, Key :: metadata()}.
handle_call(open, _From, #state{last_applied = LastApplied} = State) ->
    {reply, {ok, LastApplied}, State};

handle_call(snapshot_create, _From, #state{last_applied = #raft_log_pos{index = LastIndex, term = LastTerm}} = State) ->
    Name = ?SNAPSHOT_NAME(LastIndex, LastTerm),
    case create_snapshot_impl(Name, State) of
        ok ->
            {reply, {ok, #raft_log_pos{index = LastIndex, term = LastTerm}}, State};
        {error, _} = Error ->
            {reply, Error, State}
    end;

handle_call({snapshot_create, Name}, _From, State) ->
    Result = create_snapshot_impl(Name, State),
    {reply, Result, State};

handle_call({snapshot_open, #raft_log_pos{index = LastIndex, term = LastTerm} = LogPos}, _From, #state{name = Name, root_dir = RootDir, module = Module, handle = Handle, last_applied = LastApplied} = State) ->
    ?LOG_NOTICE("Storage[~0p] replacing storage at ~0p with snapshot at ~0p.", [Name, LastApplied, LogPos], #{domain => [whatsapp, wa_raft]}),
    SnapshotPath = filename:join(RootDir, ?SNAPSHOT_NAME(LastIndex, LastTerm)),
    case Module:storage_open_snapshot(SnapshotPath, LogPos, Handle) of
        {ok, NewHandle} -> {reply, ok, State#state{last_applied = LogPos, handle = NewHandle}};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({read_metadata, Key}, _From, #state{module = Module, handle = Handle} = State) ->
    ?RAFT_COUNT('raft.storage.read_metadata'),
    Result = Module:storage_read_metadata(Handle, Key),
    {reply, Result, State};

handle_call(status, _From, #state{module = Module, handle = Handle} = State) ->
    Status = [
        {name, State#state.name},
        {table, State#state.table},
        {partition, State#state.partition},
        {module, State#state.module},
        {last_applied, State#state.last_applied#raft_log_pos.index}
    ],
    ModuleStatus = Module:storage_status(Handle),
    {reply, Status ++ ModuleStatus, State};

handle_call(Cmd, From, #state{name = Name} = State) ->
    ?LOG_WARNING("[~p] unexpected call ~p from ~p", [Name, Cmd, From], #{domain => [whatsapp, wa_raft]}),
    {noreply, State}.

-spec handle_cast(Request, State :: #state{}) -> {noreply, NewState :: #state{}}
    when Request ::
        cancel |
        {fulfill, term(), term()} |
        {read, gen_server:from(), wa_raft_acceptor:command()} |
        {apply, LogRecord :: wa_raft_log:log_record(), ServerTerm :: wa_raft_log:log_term()} |
        {snapshot_delete, Name :: string()}.
handle_cast(cancel, State0) ->
    State1 = cancel_pending_commits(State0),
    State2 = cancel_pending_reads(State1),
    {noreply, State2};

handle_cast({fulfill, Ref, Return}, State0) ->
    State1 = reply(Ref, Return, State0),
    {noreply, State1};

handle_cast({read, From, Command}, #state{last_applied = LastApplied} = State) ->
    {Reply, _} = execute(Command, LastApplied, State),
    gen_server:reply(From, Reply),
    {noreply, State};

% Apply an op after consensus is made
handle_cast({apply, {LogIndex, {LogTerm, _}} = LogRecord, ServerTerm}, #state{name = Name} = State0) ->
    ?LOG_DEBUG("[~p] apply ~p:~p", [Name, LogIndex, LogTerm], #{domain => [whatsapp, wa_raft]}),
    State1 = apply_impl(LogRecord, ServerTerm, State0),
    {noreply, State1};

handle_cast({snapshot_delete, SnapName}, #state{name = Name, root_dir = RootDir} = State) ->
    Result = catch file:del_dir_r(filename:join(RootDir, SnapName)),
    ?LOG_NOTICE("~100p delete snapshot ~p. result ~p", [Name, SnapName, Result], #{domain => [whatsapp, wa_raft]}),
    {noreply, State};

handle_cast(Cmd, State) ->
    ?LOG_WARNING("Unexpected cast ~p", [Cmd], #{domain => [whatsapp, wa_raft]}),
    {noreply, State}.

-spec handle_info(Request :: term(), State :: #state{}) -> {noreply, NewState :: #state{}}.
handle_info(Command, State) ->
    ?LOG_WARNING("Unexpected info ~p", [Command], #{domain => [whatsapp, wa_raft]}),
    {noreply, State}.

-spec terminate(Reason :: term(), State :: #state{}) -> term().
terminate(Reason, #state{name = Name, module = Module, handle = Handle, last_applied = LastApplied}) ->
    ?LOG_NOTICE("Storage[~0p] terminating at ~0p with reason ~0p.", [Name, LastApplied, Reason], #{domain => [whatsapp, wa_raft]}),
    Module:storage_close(Handle).

-spec code_change(_OldVsn :: term(), State :: #state{}, Extra :: term()) -> {ok, State :: #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Private functions

-spec apply_impl(Record :: wa_raft_log:log_record(), ServerTerm :: wa_raft_log:log_term(), State :: #state{}) -> NewState :: #state{}.
apply_impl({LogIndex, {LogTerm, {Ref, _} = Op}}, ServerTerm,
           #state{name = Name, table = Table, partition = Partition, last_applied = #raft_log_pos{index = LastAppliedIndex}} = State0) ->
    wa_raft_queue:fulfill_apply(Table, Partition),
    StartT = os:timestamp(),
    case LogIndex of
        LastAppliedIndex ->
            apply_delayed_reads(State0);
        _ when LogIndex =:= LastAppliedIndex + 1 ->
            {Reply, State1} = storage_apply(#raft_log_pos{index = LogIndex, term = LogTerm}, Op, State0),
            State2 = case LogTerm =:= ServerTerm of
                true -> reply(Ref, Reply, State1);
                false -> State1
            end,
            State3 = State2#state{last_applied = #raft_log_pos{index = LogIndex, term = LogTerm}},
            State4 = apply_delayed_reads(State3),
            ?LOG_DEBUG("applied ~p:~p", [LogIndex, LogTerm], #{domain => [whatsapp, wa_raft]}),
            ?RAFT_GATHER('raft.storage.apply.func', timer:now_diff(os:timestamp(), StartT)),
            State4;
        _ ->
            ?LOG_ERROR("[~p] received out-of-order apply with index ~p. (expected index ~p, op ~0P)", [Name, LogIndex, LastAppliedIndex, Op, 30], #{domain => [whatsapp, wa_raft]}),
            error(out_of_order_apply)
    end.

-spec storage_apply(wa_raft_log:log_pos(), wa_raft_acceptor:op(), #state{}) -> {term(), #state{}}.
storage_apply(LogPos, {_Ref, Command}, State) ->
    ?RAFT_COUNT('raft.storage.apply'),
    execute(Command, LogPos, State).

-spec execute(Command :: wa_raft_acceptor:command(), LogPos :: wa_raft_log:log_pos(), State :: #state{}) -> {term() | error(), #state{}}.
execute(noop, LogPos, #state{module = Module, handle = Handle} = State) ->
    {Reply, NewHandle} = Module:storage_apply(noop, LogPos, Handle),
    {Reply, State#state{handle = NewHandle}};
execute({config, Config}, #raft_log_pos{index = Index, term = Term} = Version, #state{name = Name, module = Module, handle = Handle} = State) ->
    ?LOG_INFO("Storage[~p] applying new configuration ~p at ~p:~p.",
        [Name, Config, Index, Term], #{domain => [whatsapp, wa_raft]}),
    {Module:storage_write_metadata(Handle, config, Version, Config), State};
execute({execute, Table, _Key, Mod, Fun, Args}, LogPos, #state{partition = Partition, handle = Handle} = State) ->
    Result = try
        erlang:apply(Mod, Fun, [Handle, LogPos, Table] ++ Args)
    catch
        _T:Error:Stack ->
            ?RAFT_COUNT('raft.storage.apply.execute.error'),
            ?LOG_WARNING("Execute ~p:~p ~0P on ~p:~p. error ~p~nStack ~100P", [Mod, Fun, Args, 20, Table, Partition, Error, Stack, 100], #{domain => [whatsapp, wa_raft]}),
            {error, Error}
    end,
    {Result, State};
execute(Command, LogPos, #state{module = Module, handle = Handle} = State) ->
    {Reply, NewHandle} = Module:storage_apply(Command, LogPos, Handle),
    {Reply, State#state{handle = NewHandle}}.

-spec reply(term(), term(), #state{}) -> #state{}.
reply(Ref, Reply, #state{table = Table, partition = Partition} = State) ->
    wa_raft_queue:fulfill_commit(Table, Partition, Ref, Reply),
    State.

-spec apply_delayed_reads(State :: #state{}) -> NewState :: #state{}.
apply_delayed_reads(#state{table = Table, partition = Partition, last_applied = #raft_log_pos{index = LastAppliedIndex} = LastAppliedLogPos} = State) ->
    lists:foreach(
        fun ({Reference, Command}) ->
            {Reply, _} = execute(Command, LastAppliedLogPos, State),
            wa_raft_queue:fulfill_read(Table, Partition, Reference, Reply)
        end, wa_raft_queue:query_reads(Table, Partition, LastAppliedIndex)),
    State.

-spec cancel_pending_commits(#state{}) -> #state{}.
cancel_pending_commits(#state{table = Table, partition = Partition, name = Name} = State) ->
    ?LOG_NOTICE("[~p] cancel pending commits", [Name], #{domain => [whatsapp, wa_raft]}),
    wa_raft_queue:fulfill_all_commits(Table, Partition, {error, not_leader}),
    State.

-spec cancel_pending_reads(#state{}) -> #state{}.
cancel_pending_reads(#state{table = Table, partition = Partition, name = Name} = State) ->
    ?LOG_NOTICE("[~p] cancel pending reads", [Name], #{domain => [whatsapp, wa_raft]}),
    wa_raft_queue:fulfill_all_reads(Table, Partition, {error, not_leader}),
    State.

-spec create_snapshot_impl(SnapName :: string(), Storage :: #state{}) -> ok | error().
create_snapshot_impl(SnapName, #state{name = Name, root_dir = RootDir, module = Module, handle = Handle} = State) ->
    SnapshotPath = filename:join(RootDir, SnapName),
    case filelib:is_dir(SnapshotPath) of
        true ->
            ?LOG_NOTICE("Snapshot ~s for ~p already exists. Skipping snapshot creation.", [SnapName, Name], #{domain => [whatsapp, wa_raft]}),
            ok;
        false ->
            cleanup_snapshots(State),
            ?LOG_NOTICE("Create snapshot ~s for ~p.", [SnapName, Name], #{domain => [whatsapp, wa_raft]}),
            Module:storage_create_snapshot(SnapshotPath, Handle)
    end.

-define(MAX_RETAINED_SNAPSHOT, 1).

-spec cleanup_snapshots(#state{}) -> ok.
cleanup_snapshots(#state{root_dir = RootDir}) ->
    Snapshots = list_snapshots(RootDir),
    case length(Snapshots) > ?MAX_RETAINED_SNAPSHOT of
        true ->
            lists:foreach(
                fun ({_, Name}) ->
                    SnapshotPath = filename:join(RootDir, Name),
                    ?LOG_NOTICE("Removing snapshot \"~s\".", [SnapshotPath], #{domain => [whatsapp, wa_raft]}),
                    file:del_dir_r(SnapshotPath)
                end, lists:sublist(Snapshots, length(Snapshots) - ?MAX_RETAINED_SNAPSHOT)),
            ok;
        _ ->
            ok
    end.

%% Private functions
-spec list_snapshots(RootDir :: string()) -> [{wa_raft_log:log_pos(), file:filename()}].
list_snapshots(RootDir) ->
    Dirs = filelib:wildcard(?SNAPSHOT_PREFIX ++ ".*", RootDir),
    Snapshots = lists:filtermap(fun decode_snapshot_name/1, Dirs),
    lists:keysort(1, Snapshots).

-spec decode_snapshot_name(Name :: string()) -> {true, {wa_raft_log:log_pos(), file:filename()}} | false.
decode_snapshot_name(Name) ->
    case string:lexemes(Name, ".") of
        [?SNAPSHOT_PREFIX, IndexStr, TermStr] ->
            case {list_to_integer(IndexStr), list_to_integer(TermStr)} of
                {Index, Term} when Index >= 0 andalso Term >= 0 ->
                    {true, {#raft_log_pos{index = Index, term = Term}, Name}};
                _ ->
                    ?LOG_WARNING("Invalid snapshot with invalid index (~p) and/or term (~p). (full name ~p)", [IndexStr, TermStr, Name], #{domain => [whatsapp, wa_raft]}),
                    false
            end;
        _ ->
            ?LOG_WARNING("Invalid snapshot dir name ~p", [Name], #{domain => [whatsapp, wa_raft]}),
            false
    end.
