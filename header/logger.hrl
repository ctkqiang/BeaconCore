%% Verbose & Technical Structured Logging - Enhanced for Production Debugging

-type log_level() :: fatal | error | warning | info | debug | security.

%% Get ISO 8601 timestamp
-define(GET_TIMESTAMP, calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}, {offset, "Z"}])).

%% Get detailed process info
-define(GET_PROC_INFO,
    try
        {memory, Mem} = process_info(self(), memory),
        {total_heap_size, Heap} = process_info(self(), total_heap_size),
        io_lib:format("pid=~w mem=~wB heap=~wB", [self(), Mem, Heap])
    catch _ ->
        io_lib:format("pid=~w", [self()])
    end
).

%% Format metadata as key=value pairs
-define(FORMAT_META(Meta),
    try
        lists:flatten([
            "[ ",
            string:join([io_lib:format("~w=~w", [K, V]) || {K, V} <- maps:to_list(Meta)], " "),
            " ]"
        ])
    catch _ ->
        io_lib:format("~p", [Meta])
    end
).

%% Technical INFO logs - with detailed context
-define(LOG_INFO(Msg),
    io:format(
        "[~s] [INFO]  ~s | ~s~n",
        [?GET_TIMESTAMP, Msg, ?GET_PROC_INFO]
    )
).
-define(LOG_INFO(Msg, Meta),
    io:format(
        "[~s] [INFO]  ~s | ~s | ~s~n",
        [?GET_TIMESTAMP, Msg, ?GET_PROC_INFO, ?FORMAT_META(Meta)]
    )
).

%% DEBUG logs - with module/function context
-define(LOG_DEBUG(Msg),
    io:format(
        "[~s] [DEBUG] [~s:~s/~w] ~s | ~s~n",
        [?GET_TIMESTAMP, ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY, Msg, ?GET_PROC_INFO]
    )
).
-define(LOG_DEBUG(Msg, Meta),
    io:format(
        "[~s] [DEBUG] [~s:~s/~w] ~s | ~s | ~s~n",
        [?GET_TIMESTAMP, ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY, Msg, ?GET_PROC_INFO, ?FORMAT_META(Meta)]
    )
).

%% NOTICE logs - with full context
-define(LOG_NOTICE(Msg),
    io:format(
        "[~s] [NOTICE] ~s | pid=~w heap=~w~n",
        [?GET_TIMESTAMP, Msg, self(), erlang:memory(total)]
    )
).
-define(LOG_NOTICE(Msg, Meta),
    io:format(
        "[~s] [NOTICE] ~s | ~s | pid=~w~n",
        [?GET_TIMESTAMP, Msg, ?FORMAT_META(Meta), self()]
    )
).

%% WARN logs - with stack trace context
-define(LOG_WARN(Msg),
    io:format(
        "[~s] [WARN]   ~s | pid=~w [~s:~s/~w]~n",
        [?GET_TIMESTAMP, Msg, self(), ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY]
    )
).
-define(LOG_WARN(Msg, Meta),
    io:format(
        "[~s] [WARN]   ~s | ~s | [~s:~s/~w]~n",
        [?GET_TIMESTAMP, Msg, ?FORMAT_META(Meta), ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY]
    )
).

%% WARNING (alias for WARN)
-define(LOG_WARNING(Msg), ?LOG_WARN(Msg)).
-define(LOG_WARNING(Msg, Meta), ?LOG_WARN(Msg, Meta)).

%% ERROR logs - with full diagnostic info
-define(LOG_ERROR(Msg),
    io:format(
        "[~s] [ERROR]  ~s | pid=~w mem=~wB [~s:~s/~w] line=~w~n",
        [?GET_TIMESTAMP, Msg, self(), erlang:memory(total), ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY, ?LINE]
    )
).
-define(LOG_ERROR(Msg, Meta),
    io:format(
        "[~s] [ERROR]  ~s | ~s | pid=~w [~s:~s/~w:~w]~n",
        [?GET_TIMESTAMP, Msg, ?FORMAT_META(Meta), self(), ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY, ?LINE]
    )
).

%% FATAL logs - with full stack and system info
-define(LOG_FATAL(Msg),
    io:format(
        "[~s] [FATAL]  CRITICAL ERROR: ~s~n" ++
        "         pid=~w node=~w line=~w~n" ++
        "         module=~s function=~s/~w~n" ++
        "         memory=~wB processes=~w~n",
        [?GET_TIMESTAMP, Msg, self(), node(), ?LINE, ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY,
         erlang:memory(total), erlang:system_info(process_count)]
    )
).
-define(LOG_FATAL(Msg, Meta),
    io:format(
        "[~s] [FATAL]  CRITICAL ERROR: ~s~n" ++
        "         ~s~n" ++
        "         pid=~w node=~w line=~w~n" ++
        "         module=~s function=~s/~w~n" ++
        "         memory=~wB processes=~w~n",
        [?GET_TIMESTAMP, Msg, ?FORMAT_META(Meta), self(), node(), ?LINE, ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY,
         erlang:memory(total), erlang:system_info(process_count)]
    )
).
