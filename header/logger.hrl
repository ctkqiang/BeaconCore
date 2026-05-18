%% Standard logger header - structured logging macros

-type log_level() :: fatal | error | warning | info | debug | security.

%% Structured logging macros - handle both single and multi-arity calls
-define(LOG_INFO(Msg), io:format("[INFO] ~s~n", [Msg])).
-define(LOG_INFO(Msg, Meta), io:format("[INFO] ~s | ~p~n", [Msg, Meta])).

-define(LOG_DEBUG(Msg), io:format("[DEBUG] ~s~n", [Msg])).
-define(LOG_DEBUG(Msg, Meta), io:format("[DEBUG] ~s | ~p~n", [Msg, Meta])).

-define(LOG_NOTICE(Msg), io:format("[NOTICE] ~s~n", [Msg])).
-define(LOG_NOTICE(Msg, Meta), io:format("[NOTICE] ~s | ~p~n", [Msg, Meta])).

-define(LOG_WARN(Msg), io:format("[WARN] ~s~n", [Msg])).
-define(LOG_WARN(Msg, Meta), io:format("[WARN] ~s | ~p~n", [Msg, Meta])).

-define(LOG_WARNING(Msg), io:format("[WARN] ~s~n", [Msg])).
-define(LOG_WARNING(Msg, Meta), io:format("[WARN] ~s | ~p~n", [Msg, Meta])).

-define(LOG_ERROR(Msg), io:format("[ERROR] ~s~n", [Msg])).
-define(LOG_ERROR(Msg, Meta), io:format("[ERROR] ~s | ~p~n", [Msg, Meta])).

-define(LOG_FATAL(Msg), io:format("[FATAL] ~s~n", [Msg])).
-define(LOG_FATAL(Msg, Meta), io:format("[FATAL] ~s | ~p~n", [Msg, Meta])).
