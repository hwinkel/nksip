%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @private Call dialog UAS processing module
-module(nksip_call_uas_dialog).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([request/2, response/3, update_response/3]).
-import(nksip_call_dialog, [find/2, update/3, store/2]).


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec request(nksip:request(), nksip_call:call()) ->
    {ok, nksip_call:call()} | {error, nksip:sipreply()}.

request(#sipmsg{class={req, 'ACK'}}=Req, Call) ->
    ack(Req, Call);

request(Req, Call) ->
    #sipmsg{class={req, Method}, cseq=CSeq, dialog_id=DialogId} = Req,
    case find(DialogId, Call) of
        #dialog{remote_seq=RemoteSeq}=Dialog ->
            ?call_debug("Dialog ~s UAS request ~p", [DialogId, Method], Call),
            case RemoteSeq>0 andalso CSeq<RemoteSeq of
                true ->
                    {error, {internal_error, <<"Old CSeq in Dialog">>}};
                false -> 
                    Dialog1 = Dialog#dialog{remote_seq=CSeq},
                    do_request(Method, Req, Dialog1, Call)
            end;
        not_found when Method=='NOTIFY' ->
            case nksip_call_event:is_event(Req, Call) of
                true -> {ok, Call};
                false -> {error, no_transaction}
            end;
        not_found -> 
            {error, no_transaction}
    end.


%% @private
-spec do_request(nksip:method(), nksip:request(), nksip:dialog(), nksip_call:call()) ->
    {ok, nksip_call:call()} | {error, nksip:sipreply()}.

do_request('INVITE', Req, #dialog{invite=undefined}=Dialog, Call) ->
    Invite = #invite{status=confirmed},
    do_request('INVITE', Req, Dialog#dialog{invite=Invite}, Call);

do_request('INVITE', Req, 
           #dialog{invite=#invite{status=confirmed}=Invite}=Dialog, Call) ->
    {HasSDP, SDP, Offer, _} = get_sdp(Req, Invite),
    case HasSDP of
        true when Offer/=undefined ->
            {error, request_pending};
        _ ->
            Offer1 = case HasSDP of 
                true -> {remote, invite, SDP};
                false -> undefined
            end,
            Invite1 = Invite#invite{
                status = proceeding_uas,
                class = uas,
                request = Req, 
                response = undefined, 
                ack = undefined,
                sdp_offer = Offer1,
                sdp_answer = undefined
            },
            {ok, update(none, Dialog#dialog{invite=Invite1}, Call)}
    end;

do_request('INVITE', _Req, #dialog{invite=#invite{status=Status}}, _Call) ->
    case Status of
        proceeding_uac -> {error, request_pending};
        accepted_uac -> {error, request_pending};
        proceeding_uas -> {error, retry()};
        accepted_uas -> {error, retry()}
    end;

do_request('BYE', _Req, #dialog{invite=#invite{}=Invite}=Dialog, Call) ->
    #dialog{id=DialogId} = Dialog,
    #invite{status=Status} = Invite,
    case Status of
        confirmed -> ok;
        _ -> ?call_debug("Dialog ~s (~p) received BYE", [DialogId, Status], Call)
    end,
    {ok, update({invite, bye}, Dialog, Call)};

do_request('PRACK', Req, 
           #dialog{invite=#invite{status=proceeding_uas}=Invite}=Dialog, Call) ->
    {HasSDP, SDP, Offer, _Answer} = get_sdp(Req, Invite),
    case Offer of
        undefined when HasSDP ->
            Invite1 = Invite#invite{sdp_offer={remote, prack, SDP}},
            {ok, update(none, Dialog#dialog{invite=Invite1}, Call)};
        {local, invite, _} when HasSDP -> 
            Invite1 = Invite#invite{sdp_answer={remote, prack, SDP}},
            {ok, update(prack, Dialog#dialog{invite=Invite1}, Call)};
        _ -> 
            % If {local, invite, _} and no SDP, ACK must answer or delete
            {ok, update(none, Dialog, Call)}
    end;

do_request('PRACK', _Req, _Dialog, _Call) ->
    {error, request_pending};

do_request('UPDATE', Req, #dialog{invite=#invite{}=Invite}=Dialog, Call) ->
    {HasSDP, SDP, Offer, _} = get_sdp(Req, Invite),
    case Offer of
        undefined when HasSDP -> 
            Invite1 = Invite#invite{sdp_offer={remote, update, SDP}},
            {ok, update(none, Dialog#dialog{invite=Invite1}, Call)};
        undefined ->
            {ok, update(none, Dialog, Call)};
        {local, _, _} -> 
            {error, request_pending};
        {remote, _, _} -> 
            {error, retry()}
    end;

do_request('SUBSCRIBE', Req, Dialog, Call) ->
    case nksip_call_event:uas_request(Req, Dialog, Call) of
        {ok, Dialog1} -> {ok, update(none, Dialog1, Call)};
        {error, Error} -> {error, Error}
    end;
        
do_request('NOTIFY', Req, Dialog, Call) ->
    case nksip_call_event:uas_request(Req, Dialog, Call) of
        {ok, Dialog1} -> {ok, update(none, Dialog1, Call)};
        {error, Error} -> {error, Error}
    end;

do_request('REFER', Req, Dialog, Call) ->
    do_request('SUBSCRIBE', Req, Dialog, Call);

do_request(_, _, Dialog, Call) ->
    {ok, update(none, Dialog, Call)}.


%% @private
-spec response(nksip:request(), nksip:response(), nksip_call:call()) ->
    nksip_call:call().

response(Req, Resp, Call) ->
    #sipmsg{class={req, Method}, body=Body} = Req,
    #sipmsg{class={resp, Code, _Reason}, dialog_id=DialogId} = Resp,
    case find(DialogId, Call) of
        #dialog{}=Dialog ->
            ?call_debug("Dialog ~s UAS ~p response ~p", 
                         [DialogId, Method, Code], Call),
            do_response(Method, Code, Req, Resp, Dialog, Call);
        not_found when Code>100 andalso Code<300 andalso Method=='INVITE' ->
            ?call_debug("Dialog ~s UAS ~p response ~p", 
                        [DialogId, Method, Code], Call),
            Offer = case Body of 
                #sdp{}=SDP -> {remote, invite, SDP};
                _ -> undefined
            end,
            Dialog1 = nksip_call_dialog:create(uas, Req, Resp, Call),
            Invite = #invite{
                status = proceeding_uas,
                class = uas,
                request = Req, 
                response = undefined, 
                ack = undefined,
                sdp_offer = Offer,
                sdp_answer = undefined
            },
            Dialog2 = Dialog1#dialog{invite=Invite},
            do_response(Method, Code, Req, Resp, Dialog2, Call);
        not_found when Code>=200 andalso Code<300 andalso 
                       (Method=='SUBSCRIBE' orelse Method=='NOTIFY' orelse
                        Method=='REFER') ->
            ?call_debug("Dialog ~s UAS ~p response ~p", 
                        [DialogId, Method, Code], Call),
            Dialog1 = nksip_call_dialog:create(uas, Req, Resp, Call),
            do_response(Method, Code, Req, Resp, Dialog1, Call);
        not_found ->
            Call
    end.


%% @private
-spec do_response(nksip:method(), nksip:response_code(), nksip:request(),
                  nksip:response(), nksip:dialog(), nksip_call:call()) ->
    nksip_call:call().

do_response(_, Code, _Req, _Resp, _Dialog, Call) when Code<101 ->
    Call;

%% Full dialog stop reasons (RFC5057)
do_response(_Method, Code, _Req, _Resp, Dialog, Call) 
            when Code==404; Code==410; Code==416; Code==482; Code==483; Code==484;
                 Code==485; Code==502; Code==604 ->
    nksip_call_dialog:stop(Code, Dialog, Call);

do_response(_Method, Code, _Req, _Resp, #dialog{invite=#invite{}}=Dialog, Call) 
            when Code==481 ->
    update({invite, {stop, Code}}, Dialog, Call);

do_response('INVITE', Code, Req, Resp, 
            #dialog{invite=#invite{status=proceeding_uas}=Invite}=Dialog, Call) 
            when Code>100 andalso Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Invite),
    {Offer1, Answer1} = case Offer of
        {remote, invite, _} when HasSDP ->
            {Offer, {local, invite, SDP}};
        {remote, invite, _} when Code>=200 ->
            {undefined, undefined};
        undefined when HasSDP, element(1, Req#sipmsg.body)==sdp ->
            % New answer to previous INVITE offer, it is not a new offer
           {{remote, invite, Req#sipmsg.body}, {local, invite, SDP}};
        undefined when HasSDP ->
            {{local, invite, SDP}, undefined};
        {local, invite, _} when HasSDP ->
            % We are repeating a remote request
            {{local, invite, SDP}, undefined};
        _ ->
            {Offer, Answer}
    end,
    Invite1 = Invite#invite{
        response = Resp,
        sdp_offer = Offer1,
        sdp_answer = Answer1
    },
    Dialog1 = Dialog#dialog{invite=Invite1},
    case Code < 200 of
        true -> update({invite, proceeding_uas}, Dialog1, Call);
        false -> update({invite, accepted_uas}, Dialog1, Call)
    end;

do_response('INVITE', Code, _Req, Resp, 
            #dialog{invite=#invite{status=proceeding_uas}=Invite}=Dialog, Call) 
            when Code>=300 ->
    case Invite#invite.answered of
        undefined -> 
            update({invite, {stop, Code}}, Dialog, Call);
        _ -> 
            Offer1 = case Invite#invite.sdp_offer of
                {_, invite, _} -> undefined;
                {_, prack, _} -> undefined;
                Offer -> Offer
            end,
            Invite1 = Invite#invite{response=Resp, sdp_offer=Offer1},
            update({invite, confirmed}, Dialog#dialog{invite=Invite1}, Call)
    end;

do_response('INVITE', Code, _Req, _Resp, #dialog{id=DialogId}=Dialog, Call) ->
    case Dialog#dialog.invite of
        #invite{status=Status} -> ok;
        _ -> Status = undefined
    end,
    ?call_notice("Dialog UAS ~s ignoring unexpected INVITE response ~p in ~p", 
                 [DialogId, Code, Status], Call),
    update(none, Dialog, Call);

do_response('BYE', _Code, Req, _Resp, Dialog, Call) ->
    #dialog{caller_tag=CallerTag} = Dialog,
    Reason = case Req#sipmsg.from_tag of
        CallerTag -> caller_bye;
        _ -> callee_bye
    end,
    update({invite, {stop, Reason}}, Dialog, Call);

do_response('PRACK', Code, _Req, Resp, 
            #dialog{invite=#invite{}=Invite}=Dialog, Call) 
            when Code>=200, Code<300 ->
    {HasSDP, SDP, Offer, _Answer} = get_sdp(Resp, Invite),
    case Offer of
        {remote, prack, _} when HasSDP -> 
            Invite1 = Invite#invite{sdp_answer={local, prack, SDP}},
            update(prack, Dialog#dialog{invite=Invite1}, Call);
        {remote, prack, _} -> 
            Invite1 = Invite#invite{sdp_offer=undefined, sdp_answer=undefined},
            update(none, Dialog#dialog{invite=Invite1}, Call);
        _ ->
            update(none, Dialog, Call)
    end;

do_response('PRACK', Code, _Req, _Resp, 
            #dialog{invite=#invite{}=Invite}=Dialog, Call) 
            when Code>300 ->
    case Invite#invite.sdp_offer of
        {remote, prack, _} -> 
            Invite1 = Invite#invite{sdp_offer=undefined, sdp_answer=undefined},
            update(none, Dialog#dialog{invite=Invite1}, Call);
        _ -> 
            update(none, Dialog, Call)
    end;
    
do_response('UPDATE', Code, Req, Resp,
            #dialog{invite=#invite{}=Invite}=Dialog, Call)
            when Code>=200, Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Invite),
    {Offer1, Answer1} = case Offer of
        {remote, update, _} when HasSDP -> {Offer, {local, update, SDP}};
        {remote, update, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Invite1 = Invite#invite{sdp_offer=Offer1, sdp_answer=Answer1},
    update({update, uas, Req, Resp}, Dialog#dialog{invite=Invite1}, Call);

do_response('UPDATE', Code, _Req, _Resp,
            #dialog{invite=#invite{}=Invite}=Dialog, Call)
            when Code>300 ->
    case Invite#invite.sdp_offer of
        {remote, update, _} ->
            Invite1 = Invite#invite{sdp_offer=undefined, sdp_answer=undefined},
            update(none, Dialog#dialog{invite=Invite1}, Call);
        _ -> 
            update(none, Dialog, Call)
    end;
    
do_response('UPDATE', Code, Req, Resp,
            #dialog{invite=#invite{}=Invite}=Dialog, Call)
            when Code>=200, Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Invite),
    {Offer1, Answer1} = case Offer of
        {local, update, _} when HasSDP -> {Offer, {remote, update, SDP}};
        {local, update, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Invite1 = Invite#invite{sdp_offer=Offer1, sdp_answer=Answer1},
    update({update, uac, Req, Resp}, Dialog#dialog{invite=Invite1}, Call);

do_response('UPDATE', Code, _Req, _Resp, 
            #dialog{invite=#invite{}=Invite}=Dialog, Call)
            when Code>300 ->
    case Invite#invite.sdp_offer of
        {local, update, _} -> 
            Invite1 = Invite#invite{sdp_offer=undefined, sdp_answer=undefined},
            update(none, Dialog#dialog{invite=Invite1}, Call);
        _ ->
            update(none, Dialog, Call)
    end;
 
do_response('SUBSCRIBE', Code, Req, Resp, Dialog, Call) when Code>=200, Code<300 ->
    Dialog1 = nksip_call_event:uas_response(Req, Resp, Dialog, Call),
    update({subscribe, uas, Req, Resp}, Dialog1, Call);
        
do_response('SUBSCRIBE', Code, Req, Resp, Dialog, Call) when Code>=300 ->
    % If subscription ends, it will call nksip_call_dialog:update/3, removing
    % the dialog if no other use
    Dialog1 = nksip_call_event:uas_response(Req, Resp, Dialog, Call),
    update(none, Dialog1, Call);

do_response('NOTIFY', Code, Req, Resp, Dialog, Call) when Code>=200, Code<300 ->
    Dialog1 = nksip_call_event:uas_response(Req, Resp, Dialog, Call),
    update({notify, uas, Req, Resp}, Dialog1, Call);

do_response('NOTIFY', Code, Req, Resp, Dialog, Call) when Code>=300 ->
    Dialog1 = nksip_call_event:uas_response(Req, Resp, Dialog, Call),
    update(none, Dialog1, Call);

do_response('REFER', Code, Req, Resp, Dialog, Call) ->
    do_response('SUBSCRIBE', Code, Req, Resp, Dialog, Call);

do_response(_, _, _, _, Dialog, Call) ->
    update(none, Dialog, Call).


%% @private
-spec ack(nksip:request(), nksip_call:call()) ->
    {ok, nksip_call:call()} | {error, no_transaction}.

ack(#sipmsg{class={req, 'ACK'}}=AckReq, Call) ->
    #sipmsg{cseq=CSeq, dialog_id=DialogId} = AckReq,
    case find(DialogId, Call) of
        #dialog{invite=#invite{}=Invite}=Dialog ->
            #invite{status=Status, request=InvReq} = Invite,
            #sipmsg{cseq=InvSeq} = InvReq,
            ?call_debug("Dialog ~s (~p) UAS request 'ACK'", [DialogId, Status], Call),
            case Status of
                accepted_uas when CSeq==InvSeq->
                    {HasSDP, SDP, Offer, Answer} = get_sdp(AckReq, Invite), 
                    {Offer1, Answer1} = case Offer of
                        {local, invite, _} when HasSDP -> {Offer, {remote, ack, SDP}};
                        {local, invite, _} -> {undefined, undefined};
                        _ -> {Offer, Answer}
                    end,
                    Invite1 = Invite#invite{
                        ack = AckReq, 
                        sdp_offer = Offer1, 
                        sdp_answer = Answer1
                    },
                    Dialog2 = Dialog#dialog{invite=Invite1},
                    {ok, update({invite, confirmed}, Dialog2, Call)};
                confirmed ->
                    % It should be a retransmission
                    {ok, Call};
                bye ->
                    {ok, Call};
                _ ->
                    {error, no_transaction}
            end;
        not_found -> 
            {error, no_transaction}
    end.


%% @private
%% - Adds a dialog id to the response
%% - If it has no Contact, it adds the dialog's one if found
%% - For 2xx INVITE or UPDATE requests, adds a session timer to the response

-spec update_response(nksip:request(), {nksip:response(), nksip_lib:proplist()}, 
                      nksip_call:call()) ->
    {nksip:response(), nksip_lib:proplist()}.

update_response(Req, {Resp, Opts}, Call) ->
    #sipmsg{contacts=Contacts} = Resp,
    DialogId = nksip_dialog:class_id(uas, Resp),
    {Resp1, Opts1} = case Contacts of
        [] ->
            case find(DialogId, Call) of
                #dialog{local_target=LTarget} ->
                    Resp0 = Resp#sipmsg{dialog_id=DialogId, contacts=[LTarget]},
                    {Resp0, Opts -- [make_contact]};
                not_found ->
                    {Resp#sipmsg{dialog_id=DialogId}, Opts}
            end;
        _ ->
            {Resp#sipmsg{dialog_id=DialogId}, Opts}
    end,
    Resp2 = case Req of
        #sipmsg{} -> 
            nksip_call_timer:uas_update_timer(Req, Resp1, Call);
        _ ->
            % In a multiple 2xx scenario, request is already deleted at UAS
            ?call_notice("Skipping timer check because of no request", [], Call),
            Resp1 
    end,
    {Resp2, Opts1}.



%% ===================================================================
%% Utils
%% ===================================================================


%% @private
-spec get_sdp(nksip:request()|nksip:response(), nksip:invite()) ->
    {boolean(), #sdp{}|undefined, nksip_call_dialog:sdp_offer(), 
        nksip_call_dialog:sdp_offer()}.

get_sdp(#sipmsg{body=Body}, #invite{sdp_offer=Offer, sdp_answer=Answer}) ->
    case Body of
        #sdp{} = SDP -> {true, SDP, Offer, Answer};
        _ -> {false, undefined, Offer, Answer}
    end.


%% @private
retry() ->
    {
        500, 
        [{<<"Retry-After">>, crypto:rand_uniform(0, 11)}], 
        <<>>, 
        [{reason_phrase, <<"Processing Previous INVITE">>}]
    }.


