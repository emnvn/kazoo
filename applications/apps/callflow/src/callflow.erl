-module ( callflow ).

-export ( [start/0, start_link/0, stop/0] ).

start ( ) -> application:start(callflow).

start_link ( ) ->
   start_deps(),
   callflow_sup:start_link()
.

stop ( ) -> application:stop(callflow).

start_deps ( ) ->
   ensure_started(whistle_amqp),
   ensure_started(whistle_couch),
   ensure_started(dynamic_compile),
   ensure_started(log_roller)
.

ensure_started ( App ) ->
   case application:start(App) of
      ok -> ok;
      {error, {already_started, App}} -> ok
   end
.


