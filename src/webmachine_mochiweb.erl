%% @author Justin Sheehy <justin@basho.com>
%% @author Andy Gross <andy@basho.com>
%% @copyright 2007-2008 Basho Technologies
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

%% @doc Mochiweb interface for webmachine.
-module(webmachine_mochiweb).
-author('Justin Sheehy <justin@basho.com>').
-author('Andy Gross <andy@basho.com>').
-export([start/1, start/2, stop/0, stop/1, loop/2]).

-include("webmachine_logger.hrl").
-include_lib("wm_reqdata.hrl").

start(Options) ->
    {PName, Options1} = case get_option(name, Options) of
      {undefined, _} -> {?MODULE, Options};
      {PN, O1} -> {PN, O1}
    end,
    start(PName, Options1).

start(Name, Options) ->
    {DispatchList, Options1} = get_option(dispatch_list, Options),
    {Dispatcher, Options2} = get_option(dispatcher, Options1),    

    LoopOpts = [{dispatch_list, DispatchList},
                {dispatcher, Dispatcher}],

    mochiweb_http:start([{name, Name},
                         {loop, fun(MochiReq) -> 
                                        loop(MochiReq, LoopOpts)
                                end} | Options2]).

stop() ->
    {registered_name, PName} = process_info(self(), registered_name),
    stop(PName).

stop(Name) ->
    mochiweb_http:stop(Name).

init_reqdata(MochiReq) ->
    Socket = MochiReq:get(socket),
    Scheme = MochiReq:get(scheme),
    Method = MochiReq:get(method),
    RawPath = MochiReq:get(raw_path), 
    Version = MochiReq:get(version),
    Headers = MochiReq:get(headers),
    %
    ReqData0 = wrq:create(Socket,Method,Scheme,Version,RawPath,Headers),
    {Peer, ReqData} = webmachine_request:get_peer(ReqData0),
    PeerState = wrq:set_peer(Peer, ReqData),
    LogData = #wm_log_data{req_id=webmachine_id:generate(),
                           start_time=now(),
                           method=Method,
                           headers=Headers,
                           peer=PeerState#wm_reqdata.peer,
                           path=RawPath,
                           version=Version,
                           response_code=404,
                           response_length=0},
    PeerState#wm_reqdata{log_data=LogData}.

loop(MochiReq, LoopOpts) ->
    reset_process_dictionary(),

    statz:incr({zotonic, webzmachine, requests}),

    ReqData = init_reqdata(MochiReq),
    Host = case host_headers(ReqData) of
               [H|_] -> H;
               [] -> []
           end,
    Path = wrq:path(ReqData),
    {Dispatch, ReqDispatch} = case proplists:get_value(dispatcher, LoopOpts) of
                                  undefined ->
                                      DispatchList = proplists:get_vaule(dispatch_list, LoopOpts, []),
                                      {webmachine_dispatcher:dispatch(Host, Path, DispatchList), ReqData};
                                  Dispatcher ->
                                      Dispatcher:dispatch(Host, Path, ReqData)                                      
                              end,
    case Dispatch of
        {no_dispatch_match, HostId, _UnmatchedPathTokens} ->
            statz:incr({HostId, webzmachine, requests}),
            {ok, ErrorHandler} = application:get_env(webzmachine, error_handler),
            {ErrorHTML,ReqState1} = ErrorHandler:render_error(404, ReqDispatch, {none, none, []}),
            ReqState2 = webmachine_request:append_to_response_body(ErrorHTML, ReqState1),
            EndTime = now(),
            {ok,ReqState3} = webmachine_request:send_response(404, ReqState2),
            LogData = webmachine_request:log_data(ReqState3),

            statz:msec(LogData#wm_log_data.start_time, EndTime, {HostId, webzmachine, duration}),
            statz:msec(LogData#wm_log_data.start_time, EndTime, {zotonic, webzmachine, duration}),
            statz:update(LogData#wm_log_data.response_length, {HostId, webzmachine, out}),
            statz:update(LogData#wm_log_data.response_length, {zotonic, webzmachine, out}),

            webmachine_decision_core:do_log(LogData#wm_log_data{end_time=EndTime});

        {Mod, ModOpts, HostId, HostTokens, Port, PathTokens, Bindings, AppRoot, StringPath} ->
            statz:incr({webmachine, HostId, requests}),
            BootstrapResource = webmachine_resource:new(x,x,x,x),
            {ok, Resource} = BootstrapResource:wrap(ReqData, Mod, ModOpts),
            {ok,RD1} = webmachine_request:load_dispatch_data(Bindings,HostId,HostTokens,Port,PathTokens,AppRoot,StringPath,ReqDispatch),
            {ok,RD2} = webmachine_request:set_metadata('resource_module', Mod, RD1),
            try 
                case webmachine_decision_core:handle_request(Resource, RD2) of
                    {_, RsFin, RdFin} ->
                        EndTime = now(),
                        {_, RdResp} = webmachine_request:send_response(RdFin),
                        RsFin:stop(RdResp),                       

                        LogData0 = webmachine_request:log_data(RdResp),
                        StatzOpts = proplists:get_value(statz, ModOpts, []),
                        case proplists:get_value(no_duration, StatzOpts) of
                            true ->
                                nop;
                            _ -> 
                                statz:msec(LogData0#wm_log_data.start_time, EndTime, {HostId, webzmachine, duration}),
                                statz:msec(LogData0#wm_log_data.start_time, EndTime, {zotonic, webzmachine, duration})
                        end,
                        statz:update(LogData0#wm_log_data.response_length, {HostId, webzmachine, out}),
                        statz:update(LogData0#wm_log_data.response_length, {zotonic, webzmachine, out}),

                        webmachine_decision_core:do_log(LogData0#wm_log_data{resource_module=Mod, end_time=EndTime}),                        
                        ok;
                    {upgrade, UpgradeFun, RsFin, RdFin} ->
                        %%TODO: wmtracing 4xx result codes should ignore protocol upgrades? (because the code is 404 by default...)
                        RsFin:stop(RdFin),
                        Mod:UpgradeFun(RdFin, RsFin:modstate()),
                        erlang:put(mochiweb_request_force_close, true)
                end
            catch
                error:E ->
                    ?WM_DBG({error, E, erlang:get_stacktrace()}),
                    {ok,RD3} = webmachine_request:send_response(500, RD2),
                    Resource:stop(RD3),
                    case application:get_env(webzmachine, webmachine_logger_module) of
                        {ok, LogModule} -> 
                            spawn(LogModule, log_access, [webmachine_request:log_data(RD3)]);
                        _ ->
                            nop
                    end
            end;
        handled ->
            nop
    end.


get_option(Option, Options) ->
    get_option(Option, Options, undefined).

get_option(Option, Options, Default) ->
    {proplists:get_value(Option, Options, Default), proplists:delete(Option, Options)}.
    
host_headers(ReqData) ->
    [ V || V <- [wrq:get_req_header_lc(H, ReqData)
                 || H <- ["x-forwarded-host",
                          "x-forwarded-server",
                          "host"]],
     V /= undefined].



%% @doc Sometimes a connection gets re-used for different sites. Make sure that no information
%% leaks from on request to another.
reset_process_dictionary() ->
    Keys = [
        mochiweb_request_qs,
        mochiweb_request_path,
        mochiweb_request_recv,
        mochiweb_request_body,
        mochiweb_request_body_length,
        mochiweb_request_post,
        mochiweb_request_cookie,
        mochiweb_request_force_close,
        '$ancestors',
        '$initial_call',
        '$erl_eval_max_line'
    ],
    Values = [ {K, erlang:get(K)} || K <- Keys ],
    erlang:erase(),
    [ erlang:put(K, V) || {K, V} <- Values, V =/= undefined ],
    ok.
