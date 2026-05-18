%% Database type enumeration
-type database() :: MYSQL | POSTGRESSQL | ORACLEDB | SQLSERVER | D2.

%% Database connection state record
-record(db_state, {
    socket :: gen_tcp:socket() | undefined,
    host   :: string(),
    port   :: integer(),
    username :: string(),
    password :: string(),
    database :: string(),
    database_type :: database()
}).

%% Process group scope for distributed database workers
-define(DB_SCOPE, notification_scope).

%% Process group name for database workers pool
-define(DB_WORKERS_GROUP, db_workers).

%% Database connection pool constants
-define(DB_CONNECT_TIMEOUT, 5000).    % 5 seconds
-define(DB_QUERY_TIMEOUT, 30000).     % 30 seconds

%% SQL execution result types
-type query_result() :: {ok, list()} | {error, atom()}.
-type connection_result() :: {ok, pid()} | {error, atom()}.

%% Macro to get a random database worker from the pool
-define(GET_DB_WORKER, (
    case pg:get_members(?DB_SCOPE, ?DB_WORKERS_GROUP) of
        [] -> {error, no_available_connection};
        Members ->
            RandomIndex = rand:uniform(length(Members)),
            Pid = lists:nth(RandomIndex, Members),
            {ok, Pid}
    end
)).

%% Macro to execute a query with error handling
-define(DB_QUERY(SQL, Params), (
    case database_connector:query(SQL, Params) of
        {ok, Result} -> {ok, Result};
        {error, Reason} -> {error, Reason}
    end
)).
