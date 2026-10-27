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
exec_op(#{<<"op">> := <<"mesh_report">>} = Op, St) ->
    {St, mesh_report(Op, St)};
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
    St1 = wings_sel_conv:mode(Mode, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"clear_select">>} = _Op, St) ->
    St1 = wings_sel:clear(St),
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
    St1 = apply_edge_command(loop_cut, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"cut">>} = Op, St) ->
    St1 = op_cut(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"connect">>} = Op, St) ->
    St1 = op_connect(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"select_ring">>} = _Op, St) ->
    St1 = op_select_ring(St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"select_edge_ring">>} = _Op, St) ->
    St1 = op_select_ring(St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"edge_ring_cut">>} = Op, St) ->
    St1 = op_edge_ring_connect(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"edge_ring_connect">>} = Op, St) ->
    St1 = op_edge_ring_connect(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"inset">>} = Op, St) ->
    St1 = op_inset(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"move">>} = Op, St) ->
    St1 = op_move(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"scale">>} = Op, St) ->
    St1 = op_scale(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"rotate">>} = Op, St) ->
    St1 = op_rotate(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"export">>} = Op, St) ->
    Path = binary_to_list(maps:get(<<"path">>, Op)),
    Format = maps:get(<<"format">>, Op, <<"obj">>),
    IncludeUVs = bool_param(Op, <<"include_uvs">>, true),
    export_to(Path, Format, IncludeUVs, St),
    {St, #{<<"path">> => list_to_binary(Path), <<"format">> => Format,
          <<"include_uvs">> => IncludeUVs}};
exec_op(#{<<"op">> := <<"frame">>} = _Op, St) ->
    St1 = wings_view:command(frame, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"cylinder">>} = Op, St) ->
    St1 = make_cylinder(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"geodome">>} = Op, St) ->
    St1 = make_geodome(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"rename">>} = Op, St) ->
    St1 = apply_rename(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"material">>} = Op, St) ->
    St1 = apply_material(Op, St),
    {St1, scene_state(St1)};
exec_op(#{<<"op">> := <<"uv_project">>} = Op, St) ->
    {St1, Extra} = apply_uv_project(Op, St),
    {St1, maps:merge(scene_state(St1), Extra)};
exec_op(#{<<"op">> := <<"uv_transform">>} = Op, St) ->
    {St1, Extra} = apply_uv_transform(Op, St),
    {St1, maps:merge(scene_state(St1), Extra)};
exec_op(#{<<"op">> := <<"uv_dump">>} = Op, St) ->
    {St, apply_uv_dump(Op, St)};
exec_op(#{<<"op">> := <<"view">>} = Op, St) ->
    St1 = apply_view(Op, St),
    {St1, maps:merge(scene_state(St1), apply_mat_info(Op, St1))};
exec_op(#{<<"op">> := <<"mat_info">>} = Op, St) ->
    {St, apply_mat_info(Op, St)};
exec_op(#{<<"op">> := Op}, _St) ->
    throw({agent_error, <<"unknown op ", Op/binary>>}).

make_cube(Op, St) ->
    X = float_param(Op, <<"x">>, 2.0),
    Y = float_param(Op, <<"y">>, 2.0),
    Z = float_param(Op, <<"z">>, 2.0),
    Cuts = int_param(Op, <<"cuts">>, 1),
    MovX = float_param(Op, <<"mov_x">>, 0.0),
    MovY = float_param(Op, <<"mov_y">>, 0.0),
    MovZ = float_param(Op, <<"mov_z">>, 0.0),
    Ground = bool_param(Op, <<"ground">>, true),
    Arg = [{nres, Cuts}, {xcube, X}, {ycube, Y}, {zcube, Z},
           {rot_x, 0}, {rot_y, 0}, {rot_z, 0},
           {mov_x, MovX}, {mov_y, MovY}, {mov_z, MovZ},
           {ground, Ground}, {spherizeflag, false}],
    apply_shape_result(wpc_ncube:command({shape, {ncube, Arg}}, St), St).

make_cylinder(Op, St) ->
    Sections = int_param(Op, <<"sections">>, 8),
    Height = float_param(Op, <<"height">>, 2.0),
    Top = float_param(Op, <<"top_radius">>, 0.5),
    Bot = float_param(Op, <<"bottom_radius">>, 0.5),
    TopX = float_param(Op, <<"top_x">>, Top),
    TopZ = float_param(Op, <<"top_z">>, Top),
    BotX = float_param(Op, <<"bottom_x">>, Bot),
    BotZ = float_param(Op, <<"bottom_z">>, Bot),
    MovX = float_param(Op, <<"mov_x">>, 0.0),
    MovY = float_param(Op, <<"mov_y">>, 0.0),
    MovZ = float_param(Op, <<"mov_z">>, 0.0),
    Ground = bool_param(Op, <<"ground">>, true),
    Arg = [{sections, Sections}, {height, Height},
           {top_x, TopX}, {top_z, TopZ},
           {bottom_x, BotX}, {bottom_z, BotZ},
           {thickness, 0.25}, {degrees, 360.0}, {angle_offset, 0.0},
           {cylinder_type, cylinder},
           {rot_x, 0.0}, {rot_y, 0.0}, {rot_z, 0.0},
           {mov_x, MovX}, {mov_y, MovY}, {mov_z, MovZ},
           {ground, Ground}],
    apply_shape_result(wpc_cylinder:command({shape, {cylinder, Arg}}, St), St).

make_geodome(Op, St) ->
    Resolution = int_param(Op, <<"resolution">>, 1),
    Base = atom_param(Op, <<"base">>, icosahedron),
    Algorithm = atom_param(Op, <<"algorithm">>, frequency),
    Spherize = bool_param(Op, <<"spherize">>, true),
    Dome = bool_param(Op, <<"dome">>, false),
    MovX = float_param(Op, <<"mov_x">>, 0.0),
    MovY = float_param(Op, <<"mov_y">>, 0.0),
    MovZ = float_param(Op, <<"mov_z">>, 0.0),
    Scale = float_param(Op, <<"scale">>, 1.0),
    %% geodome has no built-in scale; approximate via mov + later body scale,
    %% or bake by using ground false and post-scale. Keep transform args.
    Ground = bool_param(Op, <<"ground">>, false),
    Arg = [{resolution, Resolution}, {baseflag, Base},
           {algorithmflag, Algorithm}, {spherizeflag, Spherize},
           {domeflag, Dome},
           {rot_x, 0.0}, {rot_y, 0.0}, {rot_z, 0.0},
           {mov_x, MovX}, {mov_y, MovY}, {mov_z, MovZ},
           {ground, Ground}],
    St1 = apply_shape_result(wpc_geodome:command({shape, {geodome, Arg}}, St), St),
    case abs(Scale - 1.0) < 1.0e-6 of
        true -> St1;
        false ->
            %% Select the new object (highest id) in body mode and scale.
            Id = St1#st.onext - 1,
            St2 = wings_sel:set(body, [{Id, gb_sets:singleton(0)}], St1),
            finish_drag(wings_scale:setup({uniform, center}, St2), [Scale])
    end.

apply_rename(Op, St) ->
    Id = int_param(Op, <<"object">>, default_object_id(St)),
    NameBin = maps:get(<<"name">>, Op),
    Name = binary_to_list(NameBin),
    wings_obj:update(fun(We) -> We#we{name = Name} end, [Id], St).

apply_material(Op, #st{mat=Mtab}=St0) ->
    NameBin = maps:get(<<"name">>, Op),
    NameAtom = list_to_atom(binary_to_list(NameBin)),
    R = float_param(Op, <<"r">>, 0.8),
    G = float_param(Op, <<"g">>, 0.8),
    B = float_param(Op, <<"b">>, 0.8),
    A = float_param(Op, <<"a">>, 1.0),
    {Maps, Dir} = case maps:get(<<"map_kd">>, Op, undefined) of
                      undefined -> {[], wings_pref:get_value(current_directory)};
                      PathBin when is_binary(PathBin) ->
                          Path = binary_to_list(PathBin),
                          {[{diffuse, Path}], filename:dirname(Path)}
                  end,
    %% Drop existing so maps are reloaded (add_materials skips identical mats).
    St = case gb_trees:lookup(NameAtom, Mtab) of
             none -> St0;
             {value, _} -> St0#st{mat=gb_trees:delete(NameAtom, Mtab)}
         end,
    Mat = [{opengl, [{diffuse, {R, G, B, A}}]}, {maps, Maps}],
    {St1, NewNames} = wings_material:add_materials([{NameAtom, Mat}], Dir, St),
    MatName = case NewNames of
                  [{_, N} | _] -> N;
                  [] -> NameAtom
              end,
    case bool_param(Op, <<"assign">>, true) of
        true -> wings_material:command({assign, MatName}, St1);
        false -> St1
    end.

%% view: set preview prefs (nearest filter, show textures, unlit/workmode)
apply_view(Op, St) ->
    maybe_set_pref(Op, <<"filter_texture">>, filter_texture, false,
                   fun(B) -> wings_image:filter_images(B) end),
    maybe_set_pref(Op, <<"show_textures">>, show_textures, true, fun(_) -> ok end),
    maybe_set_pref(Op, <<"workmode">>, workmode, true, fun(_) -> ok end),
    maybe_set_pref(Op, <<"show_edges">>, show_edges, true, fun(_) -> ok end),
    %% Invalidate display lists so prefs take effect.
    wings_dl:map(fun(#dlo{proxy_data=PD}=D, _) ->
                         D#dlo{work=none, smooth=none, vab=none,
                               proxy_data=wings_proxy:invalidate(PD, vab)};
                    (D, _) -> D
                 end, []),
    wings_wm:dirty(),
    St.

maybe_set_pref(Op, Key, Pref, Default, Extra) ->
    case maps:is_key(Key, Op) of
        false -> ok;
        true ->
            B = bool_param(Op, Key, Default),
            wings_pref:set_value(Pref, B),
            Extra(B)
    end.

apply_mat_info(_Op, #st{mat=Mtab}) ->
    Infos = [begin
                 Maps = case lists:keyfind(maps, 1, Props) of
                            {maps, M} -> M;
                            false -> []
                        end,
                 MapKeys = [atom_to_binary(K, utf8) || {K, _} <- Maps],
                 #{<<"name">> => atom_to_binary(Name, utf8),
                   <<"map_keys">> => MapKeys,
                   <<"has_diffuse_map">> => lists:keymember(diffuse, 1, Maps)}
             end || {Name, Props} <- gb_trees:to_list(Mtab)],
    #{<<"materials">> => Infos,
      <<"filter_texture">> => wings_pref:get_value(filter_texture, false),
      <<"show_textures">> => wings_pref:get_value(show_textures, true),
      <<"workmode">> => wings_pref:get_value(workmode, true)}.

%% ---- UV helpers (local) ----
%% uv_project: planar-project selected faces.
%%   axis: "x"|"y"|"z" (view along axis; remaining two -> U,V)
%%         "cylinder" -> U=atan2(z,x), V=y
%%   normalize: true -> fit selection to 0..1 before optional rect
%%   rect: [u0,v0,u1,v1] -> place normalized island into that UV rectangle
apply_uv_project(Op, #st{selmode=face, sel=Sel}=St) when Sel =/= [] ->
    Axis = maps:get(<<"axis">>, Op, <<"z">>),
    Raw = gather_projected(Sel, St#st.shapes, Axis),
    case Raw of
        [] -> throw({agent_error, <<"uv_project: no vertices in selection">>});
        _ ->
            Bounds0 = uv_bbox([UV || {_Id,_F,_V,UV} <- Raw]),
            Norm = bool_param(Op, <<"normalize">>, true),
            Mapped0 = case Norm of
                          true -> [{Id,F,V,norm_uv(UV, Bounds0)} || {Id,F,V,UV} <- Raw];
                          false -> Raw
                      end,
            Mapped = case maps:get(<<"rect">>, Op, undefined) of
                         undefined -> Mapped0;
                         Rect ->
                             Xf = rect_fun(Rect),
                             %% ensure normalized into rect
                             Base = case Norm of
                                        true -> Mapped0;
                                        false ->
                                            B = uv_bbox([UV || {_I,_F,_V,UV} <- Mapped0]),
                                            [{I,F,V,norm_uv(UV, B)} || {I,F,V,UV} <- Mapped0]
                                    end,
                             [{I,F,V,Xf(UV)} || {I,F,V,UV} <- Base]
                     end,
            St1 = apply_uv_assignments(Mapped, St),
            B1 = uv_bbox([UV || {_I,_F,_V,UV} <- Mapped]),
            {St1, #{<<"uv_bounds">> => encode_uv_bounds(B1),
                    <<"uv_count">> => length(Mapped),
                    <<"axis">> => Axis}}
    end;
apply_uv_project(_Op, #st{selmode=Mode, sel=Sel}) ->
    throw({agent_error,
           agent_fmt("uv_project needs face selection (mode=~w, sel_len=~p)",
                     [Mode, length(Sel)])}).

apply_uv_transform(Op, #st{selmode=face, sel=Sel}=St) when Sel =/= [] ->
    Raw = gather_existing_uvs(Sel, St#st.shapes),
    case Raw of
        [] -> throw({agent_error, <<"uv_transform: selection has no UVs; uv_project first">>});
        _ ->
            NeedNorm = maps:is_key(<<"rect">>, Op) orelse bool_param(Op, <<"normalize">>, false),
            Base = case NeedNorm of
                       true ->
                           B = uv_bbox([UV || {_I,_F,_V,UV} <- Raw]),
                           [{I,F,V,norm_uv(UV, B)} || {I,F,V,UV} <- Raw];
                       false -> Raw
                   end,
            Xf = case maps:get(<<"rect">>, Op, undefined) of
                     undefined ->
                         U = float_param(Op, <<"u">>, 0.0),
                         Voff = float_param(Op, <<"v">>, 0.0),
                         SU = float_param(Op, <<"scale_u">>, 1.0),
                         SV = float_param(Op, <<"scale_v">>, 1.0),
                         fun({X, Y}) -> {X * SU + U, Y * SV + Voff} end;
                     Rect ->
                         rect_fun(Rect)
                 end,
            Mapped = [{I,F,V,Xf(UV)} || {I,F,V,UV} <- Base],
            St1 = apply_uv_assignments(Mapped, St),
            B1 = uv_bbox([UV || {_I,_F,_V,UV} <- Mapped]),
            {St1, #{<<"uv_bounds">> => encode_uv_bounds(B1),
                    <<"uv_count">> => length(Mapped)}}
    end;
apply_uv_transform(_Op, #st{selmode=Mode, sel=Sel}) ->
    throw({agent_error,
           agent_fmt("uv_transform needs face selection (mode=~w, sel_len=~p)",
                     [Mode, length(Sel)])}).

apply_uv_dump(_Op, #st{shapes=Shs, sel=Sel}=St) ->
    Objs = [begin
                UVs = collect_object_uvs(We),
                #{<<"id">> => Id,
                  <<"name">> => obj_name(We),
                  <<"uv_count">> => length(UVs),
                  <<"uv_bounds">> => encode_uv_bounds(uv_bbox(UVs)),
                  <<"has_uvs">> => wings_va:any_uvs(We)}
            end || {Id, We} <- gb_trees:to_list(Shs)],
    SelUVs = gather_existing_uvs(Sel, Shs),
    #{<<"objects">> => Objs,
      <<"selection_uv_count">> => length(SelUVs),
      <<"selection_uv_bounds">> => encode_uv_bounds(uv_bbox([UV || {_I,_F,_V,UV} <- SelUVs])),
      <<"selection_mode">> => atom_to_binary(St#st.selmode, utf8)}.

gather_projected(Sel, Shapes, Axis) ->
    lists:append([gather_projected_obj(Id, Items, Shapes, Axis) || {Id, Items} <- Sel]).

gather_projected_obj(Id, Items, Shapes, Axis) ->
    We = gb_trees:get(Id, Shapes),
    Faces = case is_list(Items) of true -> Items; false -> gb_sets:to_list(Items) end,
    lists:append([gather_projected_face(Id, F, We, Axis) || F <- Faces]).

gather_projected_face(Id, Face, #we{vp=Vtab}=We, Axis) ->
    Vs = wings_face:vertices_ccw(Face, We),
    [{Id, Face, V, project_axis(Axis, array:get(V, Vtab))} || V <- Vs].

gather_existing_uvs(Sel, Shapes) ->
    lists:append([gather_existing_obj(Id, Items, Shapes) || {Id, Items} <- Sel]).

gather_existing_obj(Id, Items, Shapes) ->
    We = gb_trees:get(Id, Shapes),
    Faces = case is_list(Items) of true -> Items; false -> gb_sets:to_list(Items) end,
    lists:append([gather_existing_face(Id, F, We) || F <- Faces]).

gather_existing_face(Id, Face, We) ->
    %% Per-corner UV via edge_attrs (face_attr/4 returns the whole face list).
    wings_face:fold(
      fun(V, Edge, _E, Acc) ->
              case wings_va:attr(uv, wings_va:edge_attrs(Edge, Face, We)) of
                  {U, Vv} when is_float(U), is_float(Vv) ->
                      [{Id, Face, V, {U, Vv}} | Acc];
                  _ ->
                      Acc
              end
      end, [], Face, We).

apply_uv_assignments(Mapped, St) ->
    %% Group by object id, then set_vtx_face_uvs for each (V, Face, UV).
    ByObj = lists:foldl(fun({Id, F, V, UV}, Acc) ->
                                maps:update_with(Id, fun(L) -> [{F, V, UV}|L] end, [{F, V, UV}], Acc)
                        end, #{}, Mapped),
    maps:fold(fun(Id, Triples, S0) ->
                      We0 = gb_trees:get(Id, S0#st.shapes),
                      We1 = lists:foldl(fun({F, V, UV}, W) ->
                                                wings_va:set_vtx_face_uvs(V, [F], UV, W)
                                        end, We0, Triples),
                      S0#st{shapes=gb_trees:update(Id, We1, S0#st.shapes)}
              end, St, ByObj).

collect_object_uvs(We) ->
    case wings_va:any_uvs(We) of
        false -> [];
        true ->
            Faces = gb_trees:keys(We#we.fs),
            lists:append([begin
                              wings_face:fold(
                                fun(_V, Edge, _E, Acc) ->
                                        case wings_va:attr(uv, wings_va:edge_attrs(Edge, Face, We)) of
                                            {U, V} when is_float(U), is_float(V) -> [{U,V}|Acc];
                                            _ -> Acc
                                        end
                                end, [], Face, We)
                          end || Face <- Faces])
    end.

project_axis(<<"x">>, {_, Y, Z}) -> {Y, Z};
project_axis(<<"y">>, {X, _, Z}) -> {X, Z};
project_axis(<<"z">>, {X, Y, _}) -> {X, Y};
project_axis(<<"cylinder">>, {X, Y, Z}) ->
    U = math:atan2(Z, X) / (2.0 * math:pi()) + 0.5,
    {U, Y};
project_axis(A, Pos) when is_atom(A) ->
    project_axis(atom_to_binary(A, utf8), Pos);
project_axis(_, {X, Y, _}) -> {X, Y}.

uv_bbox([]) -> {0.0, 1.0, 0.0, 1.0};
uv_bbox([{U, V}|Rest]) ->
    lists:foldl(fun({X, Y}, {MiU, MaU, MiV, MaV}) ->
                        {min(MiU, X), max(MaU, X), min(MiV, Y), max(MaV, Y)}
                end, {U, U, V, V}, Rest).

norm_uv({U, V}, {MiU, MaU, MiV, MaV}) ->
    DU = max(MaU - MiU, 1.0e-9),
    DV = max(MaV - MiV, 1.0e-9),
    {(U - MiU) / DU, (V - MiV) / DV}.

rect_fun([U0, V0, U1, V1]) ->
    BU0 = float_val(U0), BV0 = float_val(V0),
    BU1 = float_val(U1), BV1 = float_val(V1),
    DU = BU1 - BU0, DV = BV1 - BV0,
    fun({X, Y}) -> {BU0 + X * DU, BV0 + Y * DV} end.

encode_uv_bounds(undefined) -> null;
encode_uv_bounds({MiU, MaU, MiV, MaV}) ->
    [MiU, MaU, MiV, MaV].

bool_param(Map, Key, Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Default;
        true -> true;
        false -> false;
        <<"true">> -> true;
        <<"false">> -> false;
        1 -> true;
        0 -> false;
        _ -> Default
    end.

atom_param(Map, Key, Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Default;
        A when is_atom(A) -> A;
        B when is_binary(B) ->
            try binary_to_existing_atom(B, utf8)
            catch error:badarg -> list_to_atom(binary_to_list(B))
            end
    end.

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
    case bool_param(Op, <<"all">>, false) of
        true ->
            Obj = int_param(Op, <<"object">>, default_object_id(St0)),
            Ids = all_ids_for_mode(Mode, Obj, St0),
            wings_sel:set(Mode, [{Obj, gb_sets:from_list(Ids)}], St0);
        false ->
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
                            ObjFilter = case maps:is_key(<<"object">>, Op) of
                                            true -> int_param(Op, <<"object">>, 0);
                                            false -> all
                                        end,
                            select_by_normal(Mode, N, Thresh, ObjFilter, St0);
                        false ->
                            throw({agent_error, <<"select requires ids, normal, or all">>})
                    end
            end
    end.

all_ids_for_mode(face, Obj, #st{shapes=Shs}) ->
    We = gb_trees:get(Obj, Shs),
    gb_trees:keys(We#we.fs);
all_ids_for_mode(edge, Obj, #st{shapes=Shs}) ->
    We = gb_trees:get(Obj, Shs),
    wings_util:array_keys(We#we.es);
all_ids_for_mode(vertex, Obj, #st{shapes=Shs}) ->
    We = gb_trees:get(Obj, Shs),
    wings_util:array_keys(We#we.vp);
all_ids_for_mode(body, _Obj, _St) ->
    [0].

select_by_normal(face, N0, Thresh, ObjFilter, #st{shapes=Shs}=St) ->
    N = e3d_vec:norm(N0),
    Shapes = case ObjFilter of
                 all -> gb_trees:to_list(Shs);
                 Id ->
                     case gb_trees:lookup(Id, Shs) of
                         {value, We} -> [{Id, We}];
                         none -> []
                     end
             end,
    Sel = [{Id, gb_sets:from_list(Faces)} ||
              {Id, We} <- Shapes,
              Faces <- [select_faces_normal(N, Thresh, We)],
              Faces =/= []],
    wings_sel:set(face, Sel, St);
select_by_normal(Mode, _N, _Thresh, _Obj, _St) ->
    throw({agent_error, io_lib:format("normal selection supports face mode only, not ~w", [Mode])}).

select_faces_normal(N, Thresh, We) ->
    Faces = gb_trees:keys(We#we.fs),
    Vtab = We#we.vp,
    [Face || Face <- Faces,
             begin
                 Vs = wings_face:vertices_ccw(Face, We),
                 Fn = wings_face:face_normal_ccw(Vs, Vtab),
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
    AxisBin = maps:get(<<"axis">>, Op, <<"uniform">>),
    ScaleVec = parse_scale_axis(AxisBin),
    finish_drag(wings_scale:setup({ScaleVec, center}, St), [Factor]).

op_rotate(Op, St) ->
    Angle = float_param(Op, <<"angle">>, 15.0),
    Axis = parse_axis(maps:get(<<"axis">>, Op, <<"y">>)),
    finish_drag(wings_rotate:setup({Axis, center}, St), [Angle]).

op_inset(Op, St) ->
    Dist = float_param(Op, <<"distance">>, 0.1),
    InsetType = parse_inset_type(maps:get(<<"type">>, Op, <<"inset_faces">>)),
    St0 = St#st{selmode=face},
    case wpc_inset:command({face, InsetType}, St0) of
        {drag, Drag} ->
            finish_drag({drag, Drag}, [Dist]);
        Other ->
            throw({agent_error, io_lib:format("inset failed: ~p", [Other])})
    end.

%% Split selected edges into N parts ({edge,{cut,N}}); hotkeys 2–0 in wings_hotkey.erl.
op_cut(Op, St) ->
    N = case maps:get(<<"segments">>, Op, 2) of
            Seg -> int_val(Seg)
        end,
    case N < 2 of
        true -> throw({agent_error, <<"segments must be at least 2">>});
        false ->
            require_mode(edge, St),
            apply_edge_command({cut, N}, St)
    end.

%% C hotkey: {edge,$c,{edge,connect}} / {vertex,$c,{vertex,connect}} — Connect, not Cut.
op_connect(Op, St) ->
    case parse_connect_variant(maps:get(<<"variant">>, Op, default)) of
        default ->
            connect_hotkey(St);
        edge ->
            require_mode(edge, St),
            apply_edge_command(connect, St);
        edge_multiple ->
            require_mode(edge, St),
            Count = int_param(Op, <<"count">>, 1),
            case wings_edge_cmd:command(connect_multiple, St) of
                {drag, Drag} ->
                    finish_drag({drag, Drag}, [Count]);
                Other ->
                    throw({agent_error, agent_fmt("connect_multiple failed: ~p", [Other])})
            end;
        vertex ->
            require_mode(vertex, St),
            apply_vertex_command(connect, St);
        vertex_cuts ->
            require_mode(vertex, St),
            apply_vertex_command(connect_cuts, St);
        vertex_connecting_edge ->
            require_mode(vertex, St),
            apply_vertex_command(connecting_edge, St);
        connect_slide ->
            throw({agent_error,
                   <<"connect_slide requires interactive slide; use variant edge instead">>})
    end.

op_select_ring(St) ->
    require_mode(edge, St),
    apply_select_command({edge_loop, edge_ring}, St).

connect_hotkey(#st{selmode=edge}=St) ->
    apply_edge_command(connect, St);
connect_hotkey(#st{selmode=vertex}=St) ->
    apply_vertex_command(connect, St);
connect_hotkey(#st{selmode=Mode}) ->
    throw({agent_error,
           agent_fmt("connect requires edge or vertex mode (C hotkey), not ~w", [Mode])}).

op_edge_ring_connect(Op, St) ->
    St1 = case maps:get(<<"expand_ring">>, Op, true) of
              true -> op_select_ring(St);
              false -> require_mode(edge, St), St
          end,
    connect_hotkey(St1).

require_mode(Mode, #st{selmode=Mode}=St) -> St;
require_mode(Mode, _St) ->
    throw({agent_error, agent_fmt("command requires ~w selection mode", [Mode])}).

apply_edge_command(Cmd, St) ->
    apply_save_state(wings_edge_cmd:command(Cmd, St), Cmd).

apply_vertex_command(Cmd, St) ->
    apply_save_state(wings_vertex_cmd:command(Cmd, St), Cmd).

apply_select_command(Cmd, St) ->
    apply_save_state(wings_sel_cmd:command(Cmd, St), Cmd).

apply_save_state({save_state, #st{}=S}, _Cmd) -> S;
apply_save_state(#st{}=S, _Cmd) -> S;
apply_save_state(Other, Cmd) ->
    throw({agent_error, agent_fmt("command ~p failed: ~p", [Cmd, Other])}).

parse_connect_variant(default) -> default;
parse_connect_variant(<<"default">>) -> default;
parse_connect_variant(<<"edge">>) -> edge;
parse_connect_variant(<<"edge_multiple">>) -> edge_multiple;
parse_connect_variant(<<"vertex">>) -> vertex;
parse_connect_variant(<<"vertex_cuts">>) -> vertex_cuts;
parse_connect_variant(<<"vertex_connecting_edge">>) -> vertex_connecting_edge;
parse_connect_variant(<<"connect_slide">>) -> connect_slide;
parse_connect_variant(B) when is_binary(B) ->
    parse_connect_variant(binary_to_existing_atom(B, utf8));
parse_connect_variant(A) when is_atom(A) -> A.

finish_drag({drag, Drag}, Move0) ->
    Units = wings_drag:drag_units(Drag),
    Move = pad_move_for_units(Units, ensure_move_list(Move0)),
    wings_drag:apply_numeric(Drag, Move);
finish_drag(Other, _Move) ->
    throw({agent_error, io_lib:format("expected drag, got ~p", [Other])}).

ensure_move_list(V) when is_number(V) -> [V];
ensure_move_list(L) when is_list(L) -> L.

pad_move_for_units([skip|Us], Vs) ->
    [0.0 | pad_move_for_units(Us, Vs)];
pad_move_for_units([_|Us], [V|Vs]) ->
    [numeric_value(V) | pad_move_for_units(Us, Vs)];
pad_move_for_units([_|Us], []) ->
    %% Default missing values (e.g. inset bump) to 0, like numeric entry.
    [0.0 | pad_move_for_units(Us, [])];
pad_move_for_units([], []) ->
    [];
pad_move_for_units([], Extra) ->
    throw({agent_error,
           agent_fmt("numeric move has extra values ~p", [Extra])}).

numeric_value(V) when is_integer(V) -> V * 1.0;
numeric_value(V) when is_float(V) -> V;
numeric_value(V) -> float_val(V).

parse_inset_type(<<"inset_faces">>) -> inset_faces;
parse_inset_type(<<"inset_region">>) -> inset_region;
parse_inset_type(<<"offset_region">>) -> offset_region;
parse_inset_type(B) when is_binary(B) -> binary_to_existing_atom(B, utf8).

export_to(Path, <<"obj">>, IncludeUVs, St) ->
    put(wings_not_running, {export, Path}),
    Attr = [{subdivisions, 0}, {tesselation, none},
            {include_uvs, IncludeUVs}, {include_normals, true}],
    _ = wpc_obj:command({file, {export, {obj, Attr}}}, St),
    erase(wings_not_running),
    ok;
export_to(Path, <<"fbx">>, _IncludeUVs, St) ->
    put(wings_not_running, {export, Path}),
    Attr = [{subdivisions, 0}, {tesselation, none}],
    _ = wpc_fbx_p:command({file, {export, {fbx_model, Attr}}}, St),
    erase(wings_not_running),
    ok;
export_to(_, Format, _, _St) ->
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


%%%
%%% mesh_report — topology / geometry / UV health from #we{}
%%%

mesh_report(Op, #st{shapes=Shs}=St) ->
    NgonMax = int_param(Op, <<"ngon_max">>, 4),
    Eps = float_param(Op, <<"epsilon">>, 1.0e-5),
    PlanRel = float_param(Op, <<"planarity_rel">>, 0.01),
    Ids = mesh_report_ids(Op, St),
    {Reports, Errors} =
        lists:foldl(
          fun(Id, {Acc, ErrAcc}) ->
                  case gb_trees:lookup(Id, Shs) of
                      none ->
                          {Acc, [#{<<"id">> => Id,
                                   <<"error">> => <<"object not found">>}|ErrAcc]};
                      {value, We} ->
                          try
                              {[mesh_report_we(Id, We, NgonMax, Eps, PlanRel)|Acc], ErrAcc}
                          catch
                              C:R:Stack ->
                                  io:format("mesh_report obj ~p ~p:~p~n~p~n",
                                            [Id, C, R, Stack]),
                                  {Acc, [#{<<"id">> => Id,
                                           <<"error">> => format_exception(C, R)}|ErrAcc]}
                          end
                  end
          end, {[], []}, Ids),
    #{<<"objects">> => lists:reverse(Reports),
      <<"errors">> => lists:reverse(Errors),
      <<"num_objects">> => length(Reports),
      <<"params">> => #{<<"ngon_max">> => NgonMax,
                        <<"epsilon">> => Eps,
                        <<"planarity_rel">> => PlanRel}}.

mesh_report_ids(Op, #st{shapes=Shs}) ->
    case maps:get(<<"objects">>, Op, undefined) of
        undefined ->
            case maps:get(<<"object">>, Op, undefined) of
                undefined -> [Id || {Id, _} <- gb_trees:to_list(Shs)];
                Id when is_integer(Id) -> [Id];
                Id when is_float(Id) -> [trunc(Id)]
            end;
        List when is_list(List) ->
            [case I of
                 N when is_integer(N) -> N;
                 N when is_float(N) -> trunc(N)
             end || I <- List]
    end.

mesh_report_we(Id, We0, NgonMax, Eps, PlanRel) ->
    We = case We0#we.fs of
             undefined -> wings_we:rebuild(We0);
             _ -> We0
         end,
    VCount = vertex_count(We),
    ECount = length(array:sparse_to_orddict(We#we.es)),
    FCount = gb_trees:size(We#we.fs),
    {MiX,MaX,MiY,MaY,MiZ,MaZ} = we_bbox(We),
    SizeX = MaX - MiX, SizeY = MaY - MiY, SizeZ = MaZ - MiZ,
    Cx = (MiX + MaX) * 0.5, Cy = (MiY + MaY) * 0.5, Cz = (MiZ + MaZ) * 0.5,
    Area = safe_surface_area(We),
    Closed = not wings_we:is_open(We) andalso We#we.holes =:= [],
    Volume = case Closed of
                 true -> safe_volume(We);
                 false -> null
             end,
    Topo = topology_health(We, NgonMax, Eps),
    Geom = geometry_health(We, Closed, {Cx, Cy, Cz}, PlanRel),
    UV = uv_health(We),
    #{<<"id">> => Id,
      <<"name">> => obj_name(We),
      <<"vertices">> => VCount,
      <<"edges">> => ECount,
      <<"faces">> => FCount,
      <<"bbox">> => #{<<"min">> => [MiX, MiY, MiZ],
                      <<"max">> => [MaX, MaY, MaZ],
                      <<"size">> => [SizeX, SizeY, SizeZ],
                      <<"center">> => [Cx, Cy, Cz]},
      <<"surface_area">> => Area,
      <<"volume">> => Volume,
      <<"closed">> => Closed,
      <<"topology">> => Topo,
      <<"geometry">> => Geom,
      <<"uv">> => UV}.

safe_surface_area(We) ->
    try float_val(wings_we:surface_area(We))
    catch _:_ -> 0.0
    end.

safe_volume(We) ->
    try abs(float_val(wings_we:volume(We)))
    catch _:_ -> 0.0
    end.

topology_health(#we{es=Etab, fs=Ftab, vp=Vtab, vc=Vct, holes=Holes}=We,
                NgonMax, Eps) ->
    HoleSet = gb_sets:from_list(Holes),
    {OpenE, NonMan} =
        lists:foldl(
          fun({_Ei, #edge{lf=Lf, rf=Rf}}, {OE, NM}) ->
                  VisL = face_visible(Lf, HoleSet),
                  VisR = face_visible(Rf, HoleSet),
                  case {VisL, VisR} of
                      {true, true} when Lf =:= Rf -> {OE, NM + 1};
                      {true, true} -> {OE, NM};
                      {false, false} -> {OE, NM};
                      _ -> {OE + 1, NM}
                  end
          end, {0, 0}, array:sparse_to_orddict(Etab)),
    Faces = gb_trees:keys(Ftab),
    {Degens, Ngons} =
        lists:foldl(
          fun(Face, {D, N}) when Face < 0 -> {D, N};
             (Face, {D, N}) ->
                  case gb_sets:is_member(Face, HoleSet) of
                      true -> {D, N};
                      false ->
                          Vs = wings_face:vertices_ccw(Face, We),
                          Sides = length(Vs),
                          Area = abs(safe_face_area(Face, We)),
                          D1 = case Area =< Eps of true -> D + 1; false -> D end,
                          N1 = case Sides > NgonMax of true -> N + 1; false -> N end,
                          {D1, N1}
                  end
          end, {0, 0}, Faces),
    Isolated = count_isolated_vertices(Vct, Vtab),
    Coincident = count_coincident_vertices(Vtab, Eps),
    #{<<"open_edges">> => OpenE,
      <<"boundary_edges">> => OpenE,
      <<"non_manifold_edges">> => NonMan,
      <<"degenerate_faces">> => Degens,
      <<"ngons">> => Ngons,
      <<"ngon_max">> => NgonMax,
      <<"isolated_vertices">> => Isolated,
      <<"coincident_vertices">> => Coincident,
      <<"holes">> => length(Holes)}.

face_visible(Face, _HoleSet) when Face < 0 -> false;
face_visible(Face, HoleSet) -> not gb_sets:is_member(Face, HoleSet).

safe_face_area(Face, We) ->
    try wings_face:area(Face, We)
    catch _:_ -> 0.0
    end.

count_isolated_vertices(undefined, _Vtab) ->
    %% No connectivity; treat all as potentially connected via positions only.
    0;
count_isolated_vertices(Vct, Vtab) ->
    lists:foldl(
      fun({V, _Pos}, Acc) ->
              case array:get(V, Vct) of
                  undefined -> Acc + 1;
                  none -> Acc + 1;
                  Edge when is_integer(Edge), Edge >= 0 -> Acc;
                  _ -> Acc + 1
              end
      end, 0, array:sparse_to_orddict(Vtab)).

count_coincident_vertices(Vtab, Eps) ->
    Pts = [P || {_V, P} <- array:sparse_to_orddict(Vtab)],
    count_coincident_1(Pts, Eps, 0).

count_coincident_1([], _Eps, Acc) -> Acc;
count_coincident_1([P|Rest], Eps, Acc) ->
    N = length([1 || Q <- Rest, e3d_vec:dist(P, Q) =< Eps]),
    count_coincident_1(Rest, Eps, Acc + N).

geometry_health(We, Closed, Centroid, PlanRel) ->
    HoleSet = gb_sets:from_list(We#we.holes),
    Faces = [F || F <- gb_trees:keys(We#we.fs),
                  F >= 0,
                  not gb_sets:is_member(F, HoleSet)],
    {NonPlanar, MaxDev, Inverted} =
        lists:foldl(
          fun(Face, {NP, MD, Inv}) ->
                  {_Dev, Rel} = face_planarity_dev(Face, We),
                  NP1 = case Rel > PlanRel of true -> NP + 1; false -> NP end,
                  MD1 = max(MD, Rel),
                  Inv1 = case Closed andalso face_points_inward(Face, We, Centroid) of
                             true -> Inv + 1;
                             false -> Inv
                         end,
                  {NP1, MD1, Inv1}
          end, {0, 0.0, 0}, Faces),
    WindBad = count_winding_inconsistencies(We, HoleSet),
    #{<<"non_planar_faces">> => NonPlanar,
      <<"max_planarity_deviation">> => MaxDev,
      <<"inverted_normals">> => Inverted,
      <<"winding_inconsistencies">> => WindBad}.

face_planarity_dev(Face, We) ->
    VsPos = wings_face:vertex_positions(Face, We),
    case VsPos of
        [] -> {0.0, 0.0};
        [_] -> {0.0, 0.0};
        [_, _] -> {0.0, 0.0};
        Pos ->
            Norm = e3d_vec:normal(Pos),
            case e3d_vec:is_zero(Norm) of
                true -> {0.0, 0.0};
                false ->
                    N = e3d_vec:norm(Norm),
                    C = e3d_vec:average(Pos),
                    D0 = e3d_vec:dot(N, C),
                    Dev = lists:foldl(
                            fun(P, Acc) ->
                                    max(Acc, abs(e3d_vec:dot(N, P) - D0))
                            end, 0.0, Pos),
                    %% Face size = max pairwise distance (cheap diameter proxy).
                    Size = face_size_proxy(Pos),
                    Rel = case Size > 1.0e-12 of
                              true -> Dev / Size;
                              false -> 0.0
                          end,
                    {Dev, Rel}
            end
    end.

face_size_proxy([P|Ps]) ->
    lists:foldl(fun(Q, Acc) -> max(Acc, e3d_vec:dist(P, Q)) end, 0.0, Ps).

face_points_inward(Face, We, Centroid) ->
    try
        Norm = wings_face:normal(Face, We),
        Center = wings_face:center(Face, We),
        Out = e3d_vec:sub(Center, Centroid),
        case e3d_vec:is_zero(Out) orelse e3d_vec:is_zero(Norm) of
            true -> false;
            false -> e3d_vec:dot(e3d_vec:norm(Norm), e3d_vec:norm(Out)) < -0.05
        end
    catch
        _:_ -> false
    end.

count_winding_inconsistencies(#we{es=Etab}=We, HoleSet) ->
    lists:foldl(
      fun({_Ei, #edge{vs=Vs, ve=Ve, lf=Lf, rf=Rf}}, Acc) ->
              VisL = face_visible(Lf, HoleSet),
              VisR = face_visible(Rf, HoleSet),
              case {VisL, VisR} of
                  {true, true} ->
                      %% On left face edge should be Vs->Ve; on right Ve->Vs.
                      %% Wings stores that by construction; verify walk order.
                      case edge_walk_ok(Lf, Vs, Ve, We) andalso
                           edge_walk_ok(Rf, Ve, Vs, We) of
                          true -> Acc;
                          false -> Acc + 1
                      end;
                  _ -> Acc
              end
      end, 0, array:sparse_to_orddict(Etab)).

edge_walk_ok(Face, From, To, We) ->
    Vs = wings_face:vertices_ccw(Face, We),
    case Vs of
        [] -> false;
        _ ->
            Ring = Vs ++ [hd(Vs)],
            edge_in_ring(Ring, From, To)
    end.

edge_in_ring([A, B|_], From, To) when A =:= From, B =:= To -> true;
edge_in_ring([_|Rest], From, To) -> edge_in_ring(Rest, From, To);
edge_in_ring([], _, _) -> false.

uv_health(We) ->
    HoleSet = gb_sets:from_list(We#we.holes),
    Faces = [F || F <- gb_trees:keys(We#we.fs),
                  F >= 0,
                  not gb_sets:is_member(F, HoleSet)],
    case wings_va:any_uvs(We) of
        false ->
            #{<<"has_uvs">> => false,
              <<"faces_without_uvs">> => length(Faces),
              <<"uvs_outside_01">> => 0,
              <<"islands">> => []};
        true ->
            FaceUVs = [{F, face_uvs(F, We)} || F <- Faces],
            Without = length([1 || {_F, UVs} <- FaceUVs, UVs =:= []]),
            AllUVs = lists:append([UVs || {_F, UVs} <- FaceUVs]),
            Outside = length([1 || {U, V} <- AllUVs,
                                   U < 0.0 orelse U > 1.0 orelse
                                   V < 0.0 orelse V > 1.0]),
            Islands = uv_islands(FaceUVs, We),
            #{<<"has_uvs">> => true,
              <<"faces_without_uvs">> => Without,
              <<"uvs_outside_01">> => Outside,
              <<"uv_count">> => length(AllUVs),
              <<"uv_bounds">> => encode_uv_bounds(uv_bbox(AllUVs)),
              <<"islands">> => Islands}
    end.

face_uvs(Face, We) ->
    wings_face:fold(
      fun(_V, Edge, _E, Acc) ->
              case wings_va:attr(uv, wings_va:edge_attrs(Edge, Face, We)) of
                  {U, V} when is_float(U), is_float(V) -> [{U, V}|Acc];
                  _ -> Acc
              end
      end, [], Face, We).

uv_islands(FaceUVs, We) ->
    %% Connected components over faces that share an edge and both have UVs.
    WithUV = [F || {F, UVs} <- FaceUVs, UVs =/= []],
    UVMap = maps:from_list(FaceUVs),
    Adj = build_face_adj(WithUV, We),
    Comps = connected_components(WithUV, Adj),
    [begin
         UVs = lists:append([maps:get(F, UVMap, []) || F <- Comp]),
         {MiU, MaU, MiV, MaV} = uv_bbox(UVs),
         Outside = lists:any(fun({U, V}) ->
                                     U < 0.0 orelse U > 1.0 orelse
                                         V < 0.0 orelse V > 1.0
                             end, UVs),
         #{<<"faces">> => length(Comp),
           <<"face_ids">> => lists:sublist(lists:sort(Comp), 32),
           <<"bbox">> => encode_uv_bounds({MiU, MaU, MiV, MaV}),
           <<"outside_01">> => Outside}
     end || Comp <- Comps].

build_face_adj(Faces, #we{es=Etab}=We) ->
    %% Link faces only when they share an edge *and* UV corners match
    %% (so distinct UV projections become separate islands).
    FaceSet = gb_sets:from_list(Faces),
    lists:foldl(
      fun({Ei, #edge{vs=Vs, ve=Ve, lf=Lf, rf=Rf}}, Acc) ->
              case gb_sets:is_member(Lf, FaceSet) andalso
                   gb_sets:is_member(Rf, FaceSet) andalso
                   uv_edge_continuous(Ei, Vs, Ve, Lf, Rf, We) of
                  true ->
                      Acc1 = maps:update_with(Lf, fun(L) -> [Rf|L] end, [Rf], Acc),
                      maps:update_with(Rf, fun(L) -> [Lf|L] end, [Lf], Acc1);
                  false -> Acc
              end
      end, #{}, array:sparse_to_orddict(Etab)).

uv_edge_continuous(_Edge, Vs, Ve, Lf, Rf, We) ->
    %% Each (V,Face) UV lives on the face-walk edge that yields that V —
    %% not on the shared geometric edge for both endpoints.
    case {vtx_face_uv(Vs, Lf, We), vtx_face_uv(Ve, Lf, We),
          vtx_face_uv(Vs, Rf, We), vtx_face_uv(Ve, Rf, We)} of
        {{U1, V1}, {U2, V2}, {U3, V3}, {U4, V4}} ->
            uv_close({U1, V1}, {U3, V3}) andalso uv_close({U2, V2}, {U4, V4});
        _ ->
            false
    end.

vtx_face_uv(V, Face, We) ->
    wings_face:fold(
      fun(Vx, Edge, _Rec, Acc) ->
              case Vx =:= V of
                  true ->
                      case wings_va:attr(uv, wings_va:edge_attrs(Edge, Face, We)) of
                          {U, VV} when is_float(U), is_float(VV) -> {U, VV};
                          _ -> Acc
                      end;
                  false -> Acc
              end
      end, undefined, Face, We).

uv_close({A, B}, {C, D}) ->
    abs(A - C) =< 1.0e-4 andalso abs(B - D) =< 1.0e-4;
uv_close(_, _) -> false.

connected_components(Nodes, Adj) ->
    connected_components(Nodes, Adj, gb_sets:empty(), []).

connected_components([], _Adj, _Seen, Acc) -> Acc;
connected_components([N|Ns], Adj, Seen, Acc) ->
    case gb_sets:is_member(N, Seen) of
        true -> connected_components(Ns, Adj, Seen, Acc);
        false ->
            {Comp, Seen1} = cc_dfs([N], Adj, Seen, []),
            connected_components(Ns, Adj, Seen1, [Comp|Acc])
    end.

cc_dfs([], _Adj, Seen, Comp) -> {Comp, Seen};
cc_dfs([N|Stack], Adj, Seen, Comp) ->
    case gb_sets:is_member(N, Seen) of
        true -> cc_dfs(Stack, Adj, Seen, Comp);
        false ->
            Neigh = maps:get(N, Adj, []),
            cc_dfs(Neigh ++ Stack, Adj, gb_sets:add_element(N, Seen), [N|Comp])
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
        false -> wings_util:gb_trees_smallest_key(Shs)
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

%% Scale axis: uniform | x|y|z | radial_x|radial_y|radial_z
parse_scale_axis(<<"uniform">>) -> uniform;
parse_scale_axis(<<"x">>) -> x;
parse_scale_axis(<<"y">>) -> y;
parse_scale_axis(<<"z">>) -> z;
parse_scale_axis(<<"radial_x">>) -> {radial, x};
parse_scale_axis(<<"radial_y">>) -> {radial, y};
parse_scale_axis(<<"radial_z">>) -> {radial, z};
parse_scale_axis(<<"radial">>) -> {radial, y};
parse_scale_axis(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8)
    catch error:badarg -> uniform
    end.

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

agent_fmt(Fmt, Args) ->
    unicode:characters_to_binary(io_lib:format(Fmt, Args)).

decode_json(Line) ->
    try
        {ok, jsone:decode(list_to_binary(Line))}
    catch
        _:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("invalid json: ~p", [Reason]))}
    end.

encode_json(Term) ->
    jsone:encode(Term).
