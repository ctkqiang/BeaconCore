-module(standard.logger).
-behaviour(gen_server).

-export([log/3, set_level/1]).
-export_type([log_level/0]).

-type log_level() :: fatal | error | warning | info | debug | security.

-define(LEVEL_KEY, current_log_level).

-spec level_to_weight(log_level()) -> integer().
level_to_weight(fatal) -> 0;
level_to_weight(error) -> 1;
level_to_weight(warning) -> 2;
level_to_weight(info) -> 3;
level_to_weight(debug) -> 4;
level_to_weight(security) -> 5.

-spec set_level(log_level()) ->
    ok.

set_level(Level) ->
    persistent_term:put(?LEVEL_KEY, level_to_weight(Level)),
    ok.

-spec log(log_level(), string(), list()) -> ok | dropped.

% Based on the currently set log level threshold, determine whether to log the message
% If the target log level weight is less than or equal to the current threshold weight, format and output the log message
% If the target log level weight is greater than the current threshold weight, drop the log message (return dropped)
% Log format is: [LEVEL_UPPERCASE] formatted message
log(Level, Format, Args) ->
    CurrentWeight = persistent_term:get(?LEVEL_KEY, 4),
    TargetWeight = level_to_weight(Level),

    case TargetWeight =< CurrentWeight of
        true ->
            Prefix = string:uppercase(atom_to_list(Level)),
            io:format("[~s] " ++ Format ++ "~n", [Prefix | Args]);
        false ->
            dropped
    end.