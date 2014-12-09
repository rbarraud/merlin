open Std
open BrowseT
       
let section = Logger.Section.of_string "destruct"

exception Not_allowed of string
exception Nothing_to_do

let () =
  Location.register_error_of_exn (function
    | Not_allowed s -> Some (Location.error ("Destruct not allowed on " ^ s))
    | Nothing_to_do -> Some (Location.error "Nothing to do")
    | _ -> None
  )

let assert_false =
  let _false = Location.mknoloc (Longident.Lident "false") in
  Ast_helper.Exp.assert_ (Ast_helper.Exp.construct _false None)

let rec gen_patterns ?(recurse=true) env type_expr =
  let open Types in
  let type_expr = Btype.repr type_expr in
  match type_expr.desc with
  | Tlink _    -> assert false (* impossible after [Btype.repr] *)
  | Tvar _     -> raise (Not_allowed "non-immediate type")
  | Tarrow _   -> raise (Not_allowed "arrow type")
  | Tobject _  -> raise (Not_allowed "object type")
  | Tpackage _ -> raise (Not_allowed "modules")
  | Ttuple lst ->
    let patterns = Parmatch.omega_list lst in
    [ Tast_helper.Pat.tuple env type_expr patterns ]
  | Tconstr (path, _params, _) ->
    begin match Env.find_type_descrs path env with
    | [], [] ->
      if recurse then from_type_decl env path else
      raise (Not_allowed (sprintf "non-destructible type: %s" (Path.last path)))
    | [], labels ->
      let lst =
        List.map labels ~f:(fun lbl_descr ->
          let lidloc = Location.mknoloc (Longident.Lident lbl_descr.lbl_name) in
          lidloc, lbl_descr,
          Tast_helper.Pat.var env type_expr (Location.mknoloc lbl_descr.lbl_name)
        )
      in
      [ Tast_helper.Pat.record env type_expr lst Asttypes.Closed ]
    | constructors, _ ->
      List.map constructors ~f:(fun cstr_descr ->
        let args =
          if cstr_descr.cstr_arity <= 0 then [] else
          Parmatch.omegas cstr_descr.cstr_arity
        in
        let lidl = Location.mknoloc (Longident.Lident cstr_descr.cstr_name) in
        Tast_helper.Pat.construct env type_expr lidl cstr_descr args
      )
    end
  | Tvariant row_desc ->
    List.filter_map row_desc.row_fields ~f:(function
      | lbl, Rpresent param_opt ->
        let popt = Option.map param_opt ~f:(fun _ -> Parmatch.omega) in
        Some (Tast_helper.Pat.variant env type_expr lbl popt (ref row_desc))
      | _, _ -> None
    )
  | _ ->
    failwith "TODO(get_patterns)"

and from_type_decl env path =
  let tdecl = Env.find_type path env in
  match tdecl.Types.type_manifest with
  | Some te -> gen_patterns ~recurse:false env te
  | None ->
    (* TODO: use [Predef] to identify int, string, etc. and destruct them in a
       meaningful way. *)
    raise (Not_allowed (sprintf "non-destructible type: %s" (Path.last path)))


let rec needs_parentheses = function
  | [] -> false
  | t :: ts ->
    match t.t_node with
    | Structure _
    | Structure_item _
    | Value_binding _ -> false
    | Expression e ->
      begin match e.Typedtree.exp_desc with
      | Typedtree.Texp_for _
      | Typedtree.Texp_while _ -> false
      | Typedtree.Texp_let _ ->
        (* We are after the "in" keyword, we need to look at the parent of the
           binding. *)
        needs_parentheses ts
      | Typedtree.Texp_function (_, cases, _) when List.length cases = 1 ->
        (* The assumption here is that we're not in a [function ... | ...]
            situation but either in [fun param] or [let name param]. *)
        needs_parentheses ts
      | _ -> true
      end
    | _ -> needs_parentheses ts

let rec get_every_pattern = function
  | [] -> assert false 
  | parent :: parents ->
    match parent.t_node with
    | Case _
    | Pattern _ ->
      (* We are still in the same branch, going up. *)
      get_every_pattern parents
    | Expression e ->
      (* We are on the right node *)
      let patterns =
        List.concat_map (Lazy.force parent.t_children) ~f:(fun c ->
          match c.t_node with
          | Pattern _ -> (* Not expected here *) assert false
          | Case _ ->
            List.filter_map (Lazy.force c.t_children) ~f:(fun patt ->
              match patt.t_node with
              | Pattern p -> Some p
              | _ -> None
            )
          | _ -> []
        )
      in
      let loc =
        let open Location in
        let init = none in
        List.fold_left (Lazy.force parent.t_children) ~init ~f:(fun l t ->
          if Lexing.compare_pos t.t_loc.loc_end l.loc_end > 0 then t.t_loc else l
        )
      in
      loc, patterns
    | _ ->
      let j = Browse_misc.dump_ts [ parent ] in
      let s = Json.to_string j in
      invalid_arg (sprintf "get_every_pattern: %s" s)(* Something went wrong. *)

let rec destructible patt =
  let open Typedtree in
  match patt.pat_desc with
  | Tpat_any | Tpat_var _ -> true
  | Tpat_alias (p, _, _)  -> destructible p
  | _ -> false

let is_package ty =
  match ty.Types.desc with
  | Types.Tpackage _ -> true
  | _ -> false

let node ~loc ~env parents node =
  match node.t_node with
  | Expression expr ->
    let ty = expr.Typedtree.exp_type in
    let pexp = Untypeast.untype_expression expr in
    let needs_parentheses, result =
      if is_package ty then (
        let name = Location.mknoloc "M" in
        let mode = Ast_helper.Mod.unpack pexp in
        false, Ast_helper.Exp.letmodule name mode assert_false
      ) else (
        let ps = gen_patterns env ty in
        let cases  =
          List.map ps ~f:(fun patt ->
            let pc_lhs = Untypeast.untype_pattern patt in
            { Parsetree. pc_lhs ; pc_guard = None ; pc_rhs = assert_false }
          )
        in
        needs_parentheses parents, Ast_helper.Exp.match_ pexp cases
      )
    in
    let fmt, to_string = Format.to_string () in
    Pprintast.expression fmt result ;
    let str = to_string () in
    let str = if needs_parentheses then "(" ^ str ^ ")" else str in
    loc, str
  | Pattern patt ->
    let last_case_loc, patterns = get_every_pattern parents in
    List.iter patterns ~f:(fun p ->
      let p = Untypeast.untype_pattern p in
      Logger.infof section ~title:"EXISTING" Pprintast.pattern p
    ) ;
    let pss = List.map patterns ~f:(fun x -> [ x ]) in
    begin match Parmatch.complete_partial pss with
    | Some pat ->
      let ppat = Untypeast.untype_pattern pat in
      let case = Ast_helper.Exp.case ppat assert_false in
      let loc =
        let open Location in
        { last_case_loc with loc_start = last_case_loc.loc_end }
      in
      let fmt, to_string = Format.to_string () in
      Pprintast.case_list fmt [ case ] ;
      loc, to_string ()
    | None ->
      if not (destructible patt) then raise Nothing_to_do else
      let ty = patt.Typedtree.pat_type in
      begin match gen_patterns env ty with
      | [] -> assert false (* we raise Not_allowed, but never return [] *)
      | [ more_precise ] ->
        (* If only one pattern is generated, then we're only refining the
           current pattern, not generating new branches. *)
        let ppat = Untypeast.untype_pattern more_precise in
        let fmt, to_string = Format.to_string () in
        Pprintast.pattern fmt ppat ;
        patt.Typedtree.pat_loc, to_string ()
      | replacement :: _ ->
        let loc = ref patt.Typedtree.pat_loc in
        let rep = ref replacement in
        let patterns =
          List.map patterns ~f:(fun p ->
            let changed, p' = Merlin_types_custom.subst_patt patt ~by:replacement p in
            if changed then (
              loc := p.Typedtree.pat_loc ;
              rep := p'
            ) ;
            p'
          )
        in
        let pss = List.map patterns ~f:(fun x -> [ x ]) in
        match Parmatch.complete_partial pss with
        | None ->
          (* [get_patterns] generated more than one, so we *must* have something
             here. *)
          assert false 
        | Some p ->
          let p = Tast_helper.Pat.pat_or env p.Typedtree.pat_type !rep p in
          let ppat = Untypeast.untype_pattern p in
          let fmt, to_string = Format.to_string () in
          Pprintast.pattern fmt ppat ;
          !loc, to_string ()
      end
    end
  | _ ->
    failwith "not handled"