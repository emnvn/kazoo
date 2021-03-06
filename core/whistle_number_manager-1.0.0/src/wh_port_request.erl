%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2015, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors:
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(wh_port_request).

-export([init/0
         ,current_state/1
         ,public_fields/1
         ,get/1
         ,normalize_attachments/1
         ,normalize_numbers/1
         ,transition_to_complete/1
         ,maybe_transition/2
         ,charge_for_port/1, charge_for_port/2
         ,send_submitted_requests/0
         ,migrate/0
        ]).

-compile({'no_auto_import', [get/1]}).

-include("wnm.hrl").
-include_lib("whistle_number_manager/include/wh_port_request.hrl").

-define(VIEW_LISTING_SUBMITTED, <<"port_requests/listing_submitted">>).

-type transition_response() :: {'ok', wh_json:object()} |
                               {'error', 'invalid_state_transition'}.

-spec init() -> _.
init() ->
    _ = couch_mgr:db_create(?KZ_PORT_REQUESTS_DB),
    couch_mgr:revise_doc_from_file(?KZ_PORT_REQUESTS_DB, 'crossbar', <<"views/port_requests.json">>).

-spec current_state(wh_json:object()) -> api_binary().
current_state(JObj) ->
    lager:debug("current state: ~p", [JObj]),
    wh_json:get_value(?PORT_PVT_STATE, JObj, ?PORT_WAITING).

-spec get(ne_binary()) ->
                 {'ok', wh_json:object()} |
                 {'error', 'not_found'}.
get(Number) ->
    wnm_number:find_port_in_number(Number).

-spec public_fields(wh_json:object()) -> wh_json:object().
public_fields(JObj) ->
    As = wh_doc:attachments(JObj, wh_json:new()),

    wh_json:set_values([{<<"id">>, wh_doc:id(JObj)}
                        ,{<<"created">>, wh_doc:created(JObj)}
                        ,{<<"updated">>, wh_doc:modified(JObj)}
                        ,{<<"uploads">>, normalize_attachments(As)}
                        ,{<<"port_state">>, wh_json:get_value(?PORT_PVT_STATE, JObj, ?PORT_WAITING)}
                        ,{<<"sent">>, wh_json:get_value(?PVT_SENT, JObj, 'false')}
                       ]
                       ,wh_doc:public_fields(JObj)
                      ).

-spec normalize_attachments(wh_json:object()) -> wh_json:object().
normalize_attachments(Attachments) ->
    wh_json:map(fun normalize_attachments_map/2, Attachments).

-spec normalize_attachments_map(wh_json:key(), wh_json:json_term()) ->
                                       {wh_json:key(), wh_json:json_term()}.
normalize_attachments_map(K, V) ->
    {K, wh_json:delete_keys([<<"digest">>, <<"revpos">>, <<"stub">>], V)}.

-spec normalize_numbers(wh_json:object()) -> wh_json:object().
normalize_numbers(JObj) ->
    Numbers = wh_json:get_value(<<"numbers">>, JObj, wh_json:new()),
    wh_json:set_value(
      <<"numbers">>
      ,wh_json:map(fun normalize_number_map/2
                   ,Numbers
                  )
      ,JObj
     ).

-spec normalize_number_map(wh_json:key(), wh_json:json_term()) ->
                                  {wh_json:key(), wh_json:json_term()}.
normalize_number_map(N, Meta) ->
    {wnm_util:to_e164(N), Meta}.

-spec transition_to_submitted(wh_json:object()) -> transition_response().
-spec transition_to_pending(wh_json:object()) -> transition_response().
-spec transition_to_scheduled(wh_json:object()) -> transition_response().
-spec transition_to_complete(wh_json:object()) -> transition_response().
-spec transition_to_rejected(wh_json:object()) -> transition_response().
-spec transition_to_canceled(wh_json:object()) -> transition_response().

transition_to_submitted(JObj) ->
    transition(JObj, [?PORT_WAITING, ?PORT_REJECT], ?PORT_SUBMITTED).

transition_to_pending(JObj) ->
    transition(JObj, [?PORT_SUBMITTED], ?PORT_PENDING).

transition_to_scheduled(JObj) ->
    transition(JObj, [?PORT_PENDING], ?PORT_SCHEDULED).

transition_to_complete(JObj) ->
    case transition(JObj, [?PORT_PENDING, ?PORT_SCHEDULED, ?PORT_REJECT], ?PORT_COMPLETE) of
        {'error', _}=E -> E;
        {'ok', Transitioned} -> completed_port(Transitioned)
    end.

transition_to_rejected(JObj) ->
    transition(JObj, [?PORT_SUBMITTED, ?PORT_PENDING, ?PORT_SCHEDULED], ?PORT_REJECT).

transition_to_canceled(JObj) ->
    transition(JObj, [?PORT_WAITING, ?PORT_SUBMITTED, ?PORT_PENDING, ?PORT_SCHEDULED, ?PORT_REJECT], ?PORT_CANCELED).

-spec maybe_transition(wh_json:object(), ne_binary()) -> transition_response().
maybe_transition(PortReq, ?PORT_SUBMITTED) ->
    transition_to_submitted(PortReq);
maybe_transition(PortReq, ?PORT_PENDING) ->
    transition_to_pending(PortReq);
maybe_transition(PortReq, ?PORT_SCHEDULED) ->
    transition_to_scheduled(PortReq);
maybe_transition(PortReq, ?PORT_COMPLETE) ->
    transition_to_complete(PortReq);
maybe_transition(PortReq, ?PORT_REJECT) ->
    transition_to_rejected(PortReq);
maybe_transition(PortReq, ?PORT_CANCELED) ->
    transition_to_canceled(PortReq).

-spec transition(wh_json:object(), ne_binaries(), ne_binary()) ->
                        transition_response().
-spec transition(wh_json:object(), ne_binaries(), ne_binary(), ne_binary()) ->
                        transition_response().
transition(JObj, FromStates, ToState) ->
    transition(JObj, FromStates, ToState, current_state(JObj)).
transition(_JObj, [], _ToState, _CurrentState) ->
    lager:debug("cant go from ~s to ~s", [_CurrentState, _ToState]),
    {'error', 'invalid_state_transition'};
transition(JObj, [CurrentState | _], ToState, CurrentState) ->
    lager:debug("going from ~s to ~s", [CurrentState, ToState]),
    {'ok', wh_json:set_value(?PORT_PVT_STATE, ToState, JObj)};
transition(JObj, [_FromState | FromStates], ToState, CurrentState) ->
    lager:debug("skipping from ~s to ~s c ~p", [_FromState, ToState, CurrentState]),
    transition(JObj, FromStates, ToState, CurrentState).

%% charge for port
-spec charge_for_port(wh_json:object()) -> 'ok' | 'error'.
-spec charge_for_port(wh_json:object(), ne_binary()) -> 'ok' | 'error'.
charge_for_port(JObj) ->
    charge_for_port(JObj, wh_doc:account_id(JObj)).
charge_for_port(_JObj, AccountId) ->
    Services = wh_services:fetch(AccountId),
    Cost = wh_services:activation_charges(<<"number_services">>, <<"port">>, Services),
    Transaction = wh_transaction:debit(AccountId, Cost),
    wh_services:commit_transactions(Services, [Transaction]).

-spec completed_port(wh_json:object()) ->
                            transition_response().
completed_port(PortReq) ->
    case charge_for_port(PortReq) of
        'ok' ->
            lager:debug("successfully charged for port, transitioning numbers to active"),
            transition_numbers(PortReq);
        'error' ->
            throw({'error', 'failed_to_charge'})
    end.

-spec transition_numbers(wh_json:object()) ->
                                transition_response().
transition_numbers(PortReq) ->
    Numbers = wh_json:get_keys(<<"numbers">>, PortReq),
    PortOps = [enable_number(N) || N <- Numbers],
    case lists:all(fun(X) -> wh_util:is_true(X) end, PortOps) of
        'true' ->
            lager:debug("all numbers ported, removing from port request"),
            ClearedPortRequest = clear_numbers_from_port(PortReq),
            {'ok', ClearedPortRequest};
        'false' ->
            lager:debug("failed to transition numbers: ~p", [PortOps]),
            {'error', PortReq}
    end.

-spec clear_numbers_from_port(wh_json:object()) -> wh_json:object().
clear_numbers_from_port(PortReq) ->
    case couch_mgr:save_doc(?KZ_PORT_REQUESTS_DB
                            ,wh_json:set_value(<<"numbers">>, wh_json:new(), PortReq)
                           )
    of
        {'ok', PortReq1} -> lager:debug("port numbers cleared"), PortReq1;
        {'error', 'conflict'} ->
            lager:debug("port request doc was updated before we could re-save"),
            PortReq;
        {'error', _E} ->
            lager:debug("failed to clear numbers: ~p", [_E]),
            PortReq
    end.

-spec enable_number(ne_binary()) -> boolean().
enable_number(N) ->
    try wh_number_manager:ported(N) of
        {'ok', _NumberDoc} ->
            lager:debug("ported ~s: ~p", [N, _NumberDoc]),
            'true';
        _E ->
            lager:debug("unexpected result to ported(~s): ~p", [N, _E]),
            {'false', N}
    catch
        'throw':_E ->
            lager:debug("throw from ported(~s): ~p", [N, _E]),
            {'false', N}
    end.

-spec send_submitted_requests() -> 'ok'.
send_submitted_requests() ->
    case couch_mgr:get_results(?KZ_PORT_REQUESTS_DB
                               ,?VIEW_LISTING_SUBMITTED
                               ,['include_docs']
                              )
    of
        {'error', _R} ->
            lager:error("failed to open view port_requests/listing_submitted ~p", [_R]);
        {'ok', JObjs} ->
            _ = [maybe_send_request(wh_json:get_value(<<"doc">>, JObj)) || JObj <- JObjs],
            lager:debug("sent requests")
    end.

-spec maybe_send_request(wh_json:object()) -> 'ok'.
-spec maybe_send_request(wh_json:object(), api_binary()) -> 'ok'.
maybe_send_request(JObj) ->
    Id = wh_doc:id(JObj),
    wh_util:put_callid(Id),

    AccountId = wh_doc:account_id(JObj),
    case kz_account:fetch(AccountId) of
        {'error', _R} ->
            lager:error("failed to open account ~s:~p", [AccountId, _R]);
        {'ok', AccountDoc} ->
            Url = wh_json:get_value(<<"submitted_port_requests_url">>, AccountDoc),
            maybe_send_request(JObj, Url)
    end.

maybe_send_request(JObj, 'undefined')->
    AccountId = wh_doc:account_id(JObj),
    lager:debug("'submitted_port_requests_url' is not set for account ~s", [AccountId]);
maybe_send_request(JObj, Url)->
    case send_request(JObj, Url) of
        'error' -> 'ok';
        'ok' ->
            case send_attachements(Url, JObj) of
                'error' -> 'ok';
                'ok' -> set_flag(JObj)
            end
    end.

-spec send_request(wh_json:object(), ne_binary()) -> 'error' | 'ok'.
send_request(JObj, Url) ->
    Id = wh_doc:id(JObj),

    Headers = [{"Content-Type", "application/json"}
               ,{"User-Agent", wh_util:to_list(erlang:node())}
              ],

    Uri = wh_util:to_list(<<Url/binary, "/", Id/binary>>),

    Remove = [<<"_rev">>
              ,<<"ui_metadata">>
              ,<<"_attachments">>
              ,<<"pvt_request_id">>
              ,<<"pvt_type">>
              ,<<"pvt_vsn">>
              ,<<"pvt_account_db">>
             ],
    Replace = [{<<"_id">>, <<"id">>}
               ,{<<"pvt_port_state">>, <<"port_state">>}
               ,{<<"pvt_account_id">>, <<"account_id">>}
               ,{<<"pvt_created">>, <<"created">>}
               ,{<<"pvt_modified">>, <<"modified">>}
              ],
    Data = wh_json:encode(wh_json:normalize_jobj(JObj, Remove, Replace)),

    case ibrowse:send_req(Uri, Headers, 'post', Data, []) of
        {'ok', "200", _Headers, _Resp} ->
            lager:debug("submitted_port_request successfully sent");
        _Other ->
            lager:error("failed to send submitted_port_request ~p", [_Other]),
            'error'
    end.

-spec send_attachements(ne_binary(), wh_json:object()) -> 'error' | 'ok'.
send_attachements(Url, JObj) ->
    try fetch_and_send(Url, JObj) of
        'ok' -> 'ok'
    catch
        'throw':'error' -> 'error'
    end.

-spec fetch_and_send(ne_binary(), wh_json:object()) -> 'ok'.
fetch_and_send(Url, JObj) ->
    Id = wh_doc:id(JObj),
    Attachments = wh_doc:attachments(JObj, wh_json:new()),

    wh_json:foldl(
      fun(Key, Value, 'ok') ->
              case couch_mgr:fetch_attachment(?KZ_PORT_REQUESTS_DB, Id, Key) of
                  {'error', _R} ->
                      lager:error("failed to fetch attachment ~s : ~p", [Key, _R]),
                      throw('error');
                  {'ok', Attachment} ->
                      send_attachement(Url, Id, Key, Value, Attachment)
              end
      end
      ,'ok'
      ,Attachments
     ).

-spec send_attachement(ne_binary(), ne_binary(), ne_binary(), wh_json:object(), _) -> 'error' | 'ok'.
send_attachement(Url, Id, Name, Options, Attachment) ->
    ContentType = wh_json:get_value(<<"content_type">>, Options),

    Headers = [{"Content-Type", wh_util:to_list(ContentType)}
               ,{"User-Agent", wh_util:to_list(erlang:node())}
              ],

    Uri =wh_util:to_list(<<Url/binary, "/", Id/binary, "/", Name/binary>>),

    case ibrowse:send_req(Uri, Headers, 'post', Attachment, []) of
        {'ok', "200", _Headers, _Resp} ->
            lager:debug("attachment ~s for submitted_port_request successfully sent", [Name]);
        _Other ->
            lager:error("failed to send attachment ~s for submitted_port_request ~p", [Name, _Other]),
            'error'
    end.

-spec set_flag(wh_json:object()) -> 'ok'.
set_flag(JObj) ->
    Doc = wh_json:set_value(?PVT_SENT, 'true', JObj),
    case couch_mgr:save_doc(?KZ_PORT_REQUESTS_DB, Doc) of
        {'ok', _} ->
            lager:debug("flag for submitted_port_request successfully set");
        {'error', _R} ->
            lager:debug("failed to set flag for submitted_port_request: ~p", [_R])
    end.

-spec migrate() -> 'ok'.
-spec migrate(binary(), pos_integer()) -> 'ok'.
migrate() ->
    wh_util:put_callid(<<"port_request_migration">>),
    lager:debug("migrating port request documents, if necessary"),

    migrate(<<>>, 10),
    lager:debug("finished migrating port request documents").

migrate(StartKey, Limit) ->
    {'ok', Docs} = fetch_docs(StartKey, Limit),
    try lists:split(Limit, Docs) of
        {Results, []} ->
            migrate_docs(Results);
        {Results, [NextResult]} ->
            migrate_docs(Results),
            lager:debug("migrated batch of ~p port requests", [Limit]),
            timer:sleep(5000),
            migrate(wh_json:get_value(<<"key">>, NextResult), Limit)
    catch
        'error':'badarg' ->
            migrate_docs(Docs)
    end.

-spec migrate_docs(wh_json:objects()) -> 'ok'.
migrate_docs([]) -> 'ok';
migrate_docs(Docs) ->
    UpdatedDocs =
        [UpdatedDoc
         || Doc <- Docs,
            (UpdatedDoc = migrate_doc(wh_json:get_value(<<"doc">>, Doc))) =/= 'undefined'
        ],
    {'ok', _} = couch_mgr:save_docs(?KZ_PORT_REQUESTS_DB, UpdatedDocs),
    'ok'.

-spec migrate_doc(wh_json:object()) -> api_object().
migrate_doc(PortRequest) ->
    case wh_json:get_value(<<"pvt_tree">>, PortRequest) of
        'undefined' -> update_doc(PortRequest);
        _Tree -> 'undefined'
    end.

-spec update_doc(wh_json:object()) -> api_object().
-spec update_doc(wh_json:object(), api_binary()) -> api_object().
update_doc(PortRequest) ->
    update_doc(PortRequest, wh_doc:account_id(PortRequest)).

update_doc(_Doc, 'undefined') ->
    lager:debug("no account id in doc ~s", [wh_doc:id(_Doc)]),
    'undefined';
update_doc(PortRequest, AccountId) ->
    {'ok', AccountDoc} = kz_account:fetch(AccountId),
    Tree = kz_account:tree(AccountDoc),
    wh_json:set_value(<<"pvt_tree">>, Tree, PortRequest).

-spec fetch_docs(binary(), pos_integer()) -> {'ok', wh_json:objects()}.
fetch_docs(StartKey, Limit) ->
    couch_mgr:all_docs(?KZ_PORT_REQUESTS_DB
                       ,[{'startkey', StartKey}
                         ,{'limit', Limit + 1}
                         ,'include_docs'
                        ]
                      ).
