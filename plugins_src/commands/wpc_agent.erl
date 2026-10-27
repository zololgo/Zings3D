%%
%%  wpc_agent.erl --
%%
%%     TCP/JSON control channel for scripted modeling (AI agents).
%%
-module(wpc_agent).

-export([init/0, menu/2, command/2]).

-include_lib("wings/src/wings.hrl").
-include_lib("wings/e3d/e3d.hrl").

-import(lists, [foldl/3, keymember/3, reverse/1]).

-define(DEFAULT_PORT, 51337).
-define(LISTEN_BACKLOG, 128).
-define(RPC_TIMEOUT, 120000).

init() ->
    case os:getenv("WINGS_AGENT_DISABLE") of
        "1" -> true;
        _ ->
            Port = listener_port(),
            spawn_link(fun() -> listener_loop(Port) end),
            true
    end.

menu(_, Menu) -> Menu.

command({agent, {exec, ReplyPid, Ref, Op}}, St) ->
    try
        {St1, Resp} = exec_op(Op, St),
        ReplyPid ! {agent_reply, Ref, {ok, Resp}},
        save_st(St1)
    catch
        throw:{agent_error, Msg} ->
            ReplyPid ! {agent_reply, Ref, {error, Msg}},
            St;
        C:R:Stack ->
            io:format("wpc_agent error ~p:~p~n~p~n", [C, R, Stack]),
            ReplyPid ! {agent_reply, Ref, {error, format_exception(C, R)}},
            St
    end;
command(_, _) -> next.

save_st(#st{}=St) -> {save_state, St};
save_st(Other) -> Other.

listener_port() ->
    case os:getenv("WINGS_AGENT_PORT") of
        false -> ?DEFAULT_PORT;
        PortStr ->
            try list_to_integer(PortStr)
            catch _:_ -> ?DEFAULT_PORT
            end
    end.

listener_loop(Port) ->
    wait_for_wings(),
    case gen_tcp:listen(Port, [{packet, line}, {active, false}, {reuseaddr, true},
                               {ip, {127, 0, 0, 1}}]) of
        {ok, Listen} ->
            io:format("wpc_agent: listening on 127.0.0.1:~p~n", [Port]),
            accept_loop(Listen);
        {error, Reason} ->
            io:format("wpc_agent: failed to listen on port ~p: ~p~n", [Port, Reason]),
            timer:sleep(5000),
            listener_loop(Port)
    end.

wait_for_wings() ->
    case whereis(wings) of
        undefined ->
            timer:sleep(200),
            wait_for_wings();
        _ -> ok
    end.

accept_loop(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            spawn(fun() -> handle_client(Socket) end),
            accept_loop(Listen);
        {error, _} ->
            timer:sleep(1000),
            accept_loop(Listen)
    end.

handle_client(Socket) ->
    try client_loop(Socket)
    after gen_tcp:close(Socket)
    end.

client_loop(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Line} ->
            Line1 = string:trim(Line, trailing, "\r\n"),
            case handle_line(Line1) of
                {ok, Response} ->
                    gen_tcp:send(Socket, [encode_json(Response), $\n]),
                    client_loop(Socket);
                {error, Response} ->
                    gen_tcp:send(Socket, [encode_json(Response), $\n]),
                    client_loop(Socket)
            end;
        {error, closed} -> ok;
        {error, _} -> ok
    end.

handle_line("") -> {ok, #{<<"ok">> => true, <<"op">> => <<"noop">>}};
handle_line(Line) ->
    case decode_json(Line) of
        {ok, Map} -> dispatch_map(Map);
        {error, Reason} ->
            {error, #{<<"ok">> => false, <<"error">> => Reason}}
    end.

dispatch_map(#{<<"op">> := Op}=Map) ->
    case rpc_wings(Map) of
        {ok, Body} ->
            {ok, maps:merge(#{<<"ok">> => true, <<"op">> => Op}, Body)};
        {error, Msg} ->
            {error, #{<<"ok">> => false, <<"op">> => Op, <<"error">> => Msg}}
    end;
dispatch_map(_) ->
    {error, #{<<"ok">> => false, <<"error">> => <<"missing op field">>}}.

rpc_wings(OpMap) ->
    Ref = make_ref(),
    Pid = self(),
    wpa:send_command({agent, {exec, Pid, Ref, OpMap}}),
    receive
        {agent_reply, Ref, Result} -> Result
    after ?RPC_TIMEOUT ->
        {error, <<"timeout">>}
    end.

%%%
%%% Command execution (runs on geom / wings process)
%%%

exec_op(#{<<"op">> := <<"ping">>} = _Op, St) ->
    {St, #{<<"message">> => <<"pong">>}};
exec_op(#{<<"op">> := <<"state">>} = _Op, St) ->
    {St, scene_state(St)};
exec_op(#{<<"op">> := <<"dump_mesh">>} = Op, St) ->
    ObjId = maps:get(<<"object">>, Op, default_object_id(St)),
    {St, dump_mesh(St, ObjId)};
exec_op(#{<<"op">> := <<"new">>} = _Op, St) ->
    St1 = apply_file_new(St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"undo">>} = _Op, St) ->
    St1 = wings_undo:undo(St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"redo">>} = _Op, St) ->
    St1 = wings_undo:redo(St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"mode">>} = Op, St) ->
    Mode = parse_mode(maps:get(<<"mode">>, Op, <<"face">>)),
    St1 = wings_sel:set(Mode, [], St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"cube">>} = Op, St) ->
    St1 = make_cube(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"select">>} = Op, St) ->
    St1 = apply_select(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"extrude">>} = Op, St) ->
    St1 = op_extrude(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"bevel">>} = Op, St) ->
    St1 = op_bevel(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"loop_cut">>} = _Op, St) ->
    St1 = wings_edge_cmd:loop_cut(St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"move">>} = Op, St) ->
    St1 = op_move(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"scale">>} = Op, St) ->
    St1 = op_scale(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"export">>} = Op, St) ->
    Path = binary_to_list(maps:get(<<"path">>, Op)),
    Format = maps:get(<<"format">>, Op, <<"obj">>),
    export_to(Path, Format, St),
    {St, #{<<"path">> => list_to_binary(Path), <<"format">> => Format}};
exec_op(#{<<"op">> := Op}, _St) ->
    throw({agent_error, <<"unknown op ", Op/binary>>}).

make_cube(Op, St) ->
    X = float_param(Op, <<"x">>, 2.0),
    Y = float_param(Op, <<"y">>, 2.0),
    Z = float_param(Op, <<"z">>, 2.0),
    Cuts = int_param(Op, <<"cuts">>, 1),
    Arg = [{nres, Cuts}, {xcube, X}, {ycube, Y}, {zcube, Z},
           {rot_x, 0}, {rot_y, 0}, {rot_z, 0},
           {mov_x, 0}, {mov_y, 0}, {mov_z, 0},
           {ground, true}, {spherizeflag, false}],
    apply_shape_result(wpc_ncube:command({shape, {ncube, Arg}}, St), St).

apply_file_new(St) ->
    case wings_file:command(confirmed_new, St) of
        {new, #st{}=St1} -> St1;
        #st{}=St1 -> St1;
        Other -> throw({agent_error, io_lib:format("new failed: ~p", [Other])})
    end.

apply_shape_result({new_shape, Prefix, Fs, Vs}, #st{onext=Oid}=St) ->
    Name = Prefix ++ integer_to_list(Oid),
    We = wings_we:build(Fs, Vs),
    wings_obj:new(Name, We, St);
apply_shape_result(#st{}=St1, _) -> St1;
apply_shape_result({save_state, #st{}=St1}, _) -> St1;
apply_shape_result(Other, _) ->
    throw({agent_error, io_lib:format("shape failed: ~p", [Other])}).

apply_select(Op, St) ->
    Mode = parse_mode(maps:get(<<"mode">>, Op, atom_to_binary(St#st.selmode, utf8))),
    St0 = wings_sel:set(Mode, [], St),
    case maps:is_key(<<"ids">>, Op) of
        true ->
            Ids = [int_val(I) || I <- maps:get(<<"ids">>, Op)],
            Obj = int_param(Op, <<"object">>, default_object_id(St0)),
            Sel = [{Obj, gb_sets:from_list(Ids)}],
            wings_sel:set(Mode, Sel, St0);
        false ->
            case maps:is_key(<<"normal">>, Op) of
                true ->
                    N = parse_vec3(maps:get(<<"normal">>, Op)),
                    Thresh = float_param(Op, <<"threshold">>, 0.9),
                    select_by_normal(Mode, N, Thresh, St0);
                false ->
                    throw({agent_error, <<"select requires ids or normal">>})
            end
    end.

select_by_normal(face, N0, Thresh, #st{shapes=Shs}=St) ->
    N = e3d_vec:norm(N0),
    Sel = [{Id, gb_sets:from_list(Faces)} ||
              {Id, We} <- gb_trees:to_list(Shs),
              Faces = select_faces_normal(N, Thresh, We),
              Faces =/= []],
    wings_sel:set(face, Sel, St);
select_by_normal(Mode, _N, _Thresh, _St) ->
    throw({agent_error, io_lib:format("normal selection supports face mode only, not ~w", [Mode])}).

select_faces_normal(N, Thresh, We) ->
    Faces = gb_trees:keys(We#we.fs),
    Vtab = We#we.vp,
    [Face || Face <- Faces,
             begin
                 Vs = wings_face:vertices_ccw(Face, We),
                 Fn = wings_face:face_normal_cw(Vs, Vtab),
                 e3d_vec:dot(N, e3d_vec:norm(Fn)) >= Thresh
             end].

op_extrude(Op, St) ->
    AxisBin = maps:get(<<"axis">>, Op, <<"normal">>),
    Axis = parse_axis(AxisBin),
    Dist = float_param(Op, <<"distance">>, 0.2),
    St0 = St#st{selmode=face},
    St1 = wings_face_cmd:extrude_region(St0),
    finish_drag(wings_move:setup(Axis, St1), [Dist]).

op_bevel(Op, St) ->
    Dist = float_param(Op, <<"distance">>, 0.1),
    case St#st.selmode of
        edge ->
            finish_drag(wings_extrude_edge:bevel(St), [Dist]);
        face ->
            St1 = wings_sel:map(fun wings_extrude_edge:bevel_faces/2, St),
            finish_drag(wings_extrude_edge:bevel_drag(St1), [Dist]);
        _ ->
            throw({agent_error, <<"bevel requires edge or face mode">>})
    end.

op_move(Op, St) ->
    Axis = parse_axis(maps:get(<<"axis">>, Op, <<"normal">>)),
    Dist = float_param(Op, <<"distance">>, 0.1),
    finish_drag(wings_move:setup(Axis, St), [Dist]).

op_scale(Op, St) ->
    Factor = float_param(Op, <<"factor">>, 1.2),
    finish_drag(wings_scale:setup({uniform, center}, St), [Factor]).

finish_drag({drag, Drag}, Move) ->
    wings_drag:apply_numeric(Drag, Move);
finish_drag(Other, _Move) ->
    throw({agent_error, io_lib:format("expected drag, got ~p", [Other])}).

export_to(Path, <<"obj">>, St) ->
    put(wings_not_running, {export, Path}),
    Attr = [{subdivisions, 0}, {tesselation, none},
            {include_uvs, false}, {include_normals, true}],
    _ = wpc_obj:command({file, {export, {obj, Attr}}}, St),
    erase(wings_not_running),
    ok;
export_to(Path, <<"fbx">>, St) ->
    put(wings_not_running, {export, Path}),
    Attr = [{subdivisions, 0}, {tesselation, none}],
    _ = wpc_fbx_p:command({file, {export, {fbx_model, Attr}}}, St),
    erase(wings_not_running),
    ok;
export_to(_, Format, _St) ->
    throw({agent_error, io_lib:format("unsupported export format ~s", [Format])}).

scene_state(#st{selmode=Mode, sel=Sel, shapes=Shs}=St) ->
    Objects = [object_summary(Id, We) || {Id, We} <- gb_trees:to_list(Shs)],
    #{<<"selection_mode">> => atom_to_binary(Mode, utf8),
      <<"selection">> => encode_selection(Sel),
      <<"objects">> => Objects,
      <<"num_objects">> => wings_obj:num_objects(St)}.

object_summary(Id, We) ->
    #{<<"id">> => Id,
      <<"name">> => obj_name(We),
      <<"vertices">> => vertex_count(We),
      <<"edges">> => array:size(We#we.es),
      <<"faces">> => gb_trees:size(We#we.fs),
      <<"bbox">> => bbox_list(we_bbox(We))}.

obj_name(#we{name=Name}) ->
    case Name of
        [] -> <<"">>;
        _ when is_list(Name) -> list_to_binary(Name);
        _ -> unicode:characters_to_binary(Name)
    end.

vertex_count(#we{vp=Vtab}) ->
    length(array:sparse_to_orddict(Vtab)).

bbox_list({MiX,MaX,MiY,MaY,MiZ,MaZ}) ->
    [MiX, MaX, MiY, MaY, MiZ, MaZ].

encode_selection(Sel) ->
    [encode_sel_entry(Id, Items) || {Id, Items} <- Sel].

encode_sel_entry(Id, Items) when is_list(Items) ->
    #{<<"object">> => Id, <<"ids">> => Items};
encode_sel_entry(Id, Items) ->
    #{<<"object">> => Id, <<"ids">> => gb_sets:to_list(Items)}.

we_bbox(#we{vp=Vtab}) ->
    case array:sparse_to_orddict(Vtab) of
        [] -> {0,0,0,0,0,0};
        Vs ->
            lists:foldl(fun({_, {X,Y,Z}}, {MiX,MaX,MiY,MaY,MiZ,MaZ}) ->
                                {min(MiX,X), max(MaX,X), min(MiY,Y), max(MaY,Y),
                                 min(MiZ,Z), max(MaZ,Z)}
                        end, {1.0e300,-1.0e300,1.0e300,-1.0e300,1.0e300,-1.0e300}, Vs)
    end.

dump_mesh(St, ObjId) ->
    case gb_trees:lookup(ObjId, St#st.shapes) of
        none -> throw({agent_error, <<"object not found">>});
        {value, We} ->
            Vtab = We#we.vp,
            Vlist = array:sparse_to_orddict(Vtab),
            Faces = [wings_face:vertices_ccw(F, We) || F <- gb_trees:keys(We#we.fs)],
            #{<<"object">> => ObjId,
              <<"vertices">> => [[X,Y,Z] || {_, {X,Y,Z}} <- Vlist],
              <<"faces">> => Faces}
    end.

default_object_id(#st{sel=[{Id,_}|_]}) -> Id;
default_object_id(#st{shapes=Shs}) ->
    case gb_trees:is_empty(Shs) of
        true -> 1;
        false -> gb_trees:smallest_key(Shs)
    end.

parse_mode(<<"vertex">>) -> vertex;
parse_mode(<<"edge">>) -> edge;
parse_mode(<<"face">>) -> face;
parse_mode(<<"body">>) -> body;
parse_mode(B) when is_binary(B) -> binary_to_existing_atom(B, utf8).

parse_axis(<<"normal">>) -> normal;
parse_axis(<<"x">>) -> x;
parse_axis(<<"y">>) -> y;
parse_axis(<<"z">>) -> z;
parse_axis(<<"uniform">>) -> uniform;
parse_axis(B) when is_binary(B) -> binary_to_existing_atom(B, utf8).

parse_vec3([X,Y,Z]) -> {float_val(X), float_val(Y), float_val(Z)};
parse_vec3(#{<<"x">> := X, <<"y">> := Y, <<"z">> := Z}) ->
    {float_val(X), float_val(Y), float_val(Z)}.

float_param(Map, Key, Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Default;
        V -> float_val(V)
    end.

int_param(Map, Key, Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Default;
        V -> int_val(V)
    end.

float_val(N) when is_integer(N) -> N * 1.0;
float_val(N) when is_float(N) -> N;
float_val(B) when is_binary(B) -> list_to_float(binary_to_list(B)).

int_val(N) when is_integer(N) -> N;
int_val(B) when is_binary(B) -> binary_to_integer(B).

format_exception(error, {badmatch, _}) -> <<"internal badmatch">>;
format_exception(error, Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason]));
format_exception(C, R) ->
    unicode:characters_to_binary(io_lib:format("~p:~p", [C, R])).

decode_json(Line) ->
    try
        {ok, jsone:decode(list_to_binary(Line))}
    catch
        _:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("invalid json: ~p", [Reason]))}
    end.

encode_json(Term) ->
    jsone:encode(Term).
