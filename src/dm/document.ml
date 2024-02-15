(**************************************************************************)
(*                                                                        *)
(*                                 VSCoq                                  *)
(*                                                                        *)
(*                   Copyright INRIA and contributors                     *)
(*       (see version control and README file for authors & dates)        *)
(*                                                                        *)
(**************************************************************************)
(*                                                                        *)
(*   This file is distributed under the terms of the MIT License.         *)
(*   See LICENSE file.                                                    *)
(*                                                                        *)
(**************************************************************************)
open Lsp
open LspData
open Types
open Scheduler
open EcLib

let Log log = Log.mk_log "document"

module LM = Map.Make (Int)

module SM = Map.Make (Stateid)

type parsed_ast = {
  ast: EcParsetree.global;
  classification: vernac_classification;
  tokens: EcParser.token list
}

type pre_sentence = {
  start : int;
  stop : int;
  synterp_state : EcLib.EcScope.scope;
  ast : parsed_ast;
}

type sentence = {
  start : int;
  stop : int;
  synterp_state : EcLib.EcScope.scope; (* synterp state after this sentence's synterp phase *)
  scheduler_state_before : Scheduler.state;
  scheduler_state_after : Scheduler.state;
  ast : parsed_ast;
  id : sentence_id;
}

type parsing_error = {
  start: int;
  stop: int;
  msg: string EcLocation.located;
}

type document = {
  sentences_by_id : sentence SM.t;
  sentences_by_end : sentence LM.t;
  parsing_errors_by_end : parsing_error LM.t;
  schedule : Scheduler.schedule;
  parsed_loc : int;
  raw_doc : RawDocument.t;
}

let schedule doc = doc.schedule

let raw_document doc = doc.raw_doc

let range_of_sentence raw (sentence : sentence) =
  let start = RawDocument.position_of_loc raw sentence.start in
  let end_ = RawDocument.position_of_loc raw sentence.stop in
  Range.{ start; end_ }

let range_of_id document id =
  match SM.find_opt id document.sentences_by_id with
  | None -> raise Not_found  (* CErrors.anomaly Pp.(str"Trying to get range of non-existing sentence " ++ Stateid.print id) *)
  | Some sentence -> range_of_sentence document.raw_doc sentence

let parse_errors parsed =
  List.map snd (LM.bindings parsed.parsing_errors_by_end)

let set_parse_errors parsed errors =
  let parsing_errors_by_end =
    List.fold_left (fun acc error -> LM.add error.stop error acc) LM.empty errors
  in
  { parsed with parsing_errors_by_end }

let add_sentence parsed start stop (ast: parsed_ast) synterp_state scheduler_state_before =
  let id = Stateid.fresh () in
  let ast' = (ast.ast, ast.classification, synterp_state) in
  let scheduler_state_after, schedule =
    Scheduler.schedule_sentence (id, ast') scheduler_state_before parsed.schedule
  in
  (* FIXME may invalidate scheduler_state_XXX for following sentences -> propagate? *)
  let sentence = { start; stop; ast; id; synterp_state; scheduler_state_before; scheduler_state_after } in
  { parsed with sentences_by_end = LM.add stop sentence parsed.sentences_by_end;
    sentences_by_id = SM.add id sentence parsed.sentences_by_id;
    schedule
  }, scheduler_state_after

let remove_sentence parsed id =
  match SM.find_opt id parsed.sentences_by_id with
  | None -> parsed
  | Some sentence ->
    let sentences_by_id = SM.remove id parsed.sentences_by_id in
    let sentences_by_end = LM.remove sentence.stop parsed.sentences_by_end in
    (* TODO clean up the schedule and free cached states *)
    { parsed with sentences_by_id; sentences_by_end; }

let sentences parsed =
  List.map snd @@ SM.bindings parsed.sentences_by_id

let sentences_sorted_by_loc parsed =
  List.sort (fun ({ start = s1 } : sentence) { start = s2 } -> s1 - s2) @@ List.map snd @@ SM.bindings parsed.sentences_by_id

(** [cata f a x] is [a] if [x] is [None] and [f y] if [x] is [Some y]. Stolen from coq core lib *)
let cata f a = function
| Some c -> f c
| None -> a

let sentences_before parsed loc =
  let (before,ov,_after) = LM.split loc parsed.sentences_by_end in
  let before = cata (fun v -> LM.add loc v before) before ov in
  List.map (fun (_id,s) -> s) @@ LM.bindings before

let sentences_after parsed loc =
  let (_before,ov,after) = LM.split loc parsed.sentences_by_end in
  let after = cata (fun v -> LM.add loc v after) after ov in
  List.map (fun (_id,s) -> s) @@ LM.bindings after

let get_sentence parsed id =
  SM.find_opt id parsed.sentences_by_id

let find_sentence parsed loc =
  match LM.find_first_opt (fun k -> loc <= k) parsed.sentences_by_end with
  | Some (_, sentence) when sentence.start <= loc -> Some sentence
  | _ -> None

let find_sentence_before parsed loc =
  match LM.find_last_opt (fun k -> k <= loc) parsed.sentences_by_end with
  | Some (_, sentence) -> Some sentence
  | _ -> None

let find_sentence_after parsed loc = 
  match LM.find_first_opt (fun k -> loc <= k) parsed.sentences_by_end with
  | Some (_, sentence) -> Some sentence
  | _ -> None

let get_first_sentence parsed = 
  Option.map snd @@ LM.find_first_opt (fun _ -> true) parsed.sentences_by_end

let get_last_sentence parsed = 
  Option.map snd @@ LM.find_last_opt (fun _ -> true) parsed.sentences_by_end

let state_after_sentence = function
| Some (stop, { synterp_state; scheduler_state_after }) ->
  (stop, synterp_state, scheduler_state_after)
| None -> (-1, EcLib.EcScope.empty @@ EcLib.EcGState.create (), Scheduler.initial_state)

(** Returns the state at position [pos] if it does not require execution *)
let state_at_pos parsed pos =
  state_after_sentence @@
    LM.find_last_opt (fun stop -> stop <= pos) parsed.sentences_by_end

let pos_at_end parsed =
  match LM.max_binding_opt parsed.sentences_by_end with
  | Some (stop, _) -> stop
  | None -> -1

type diff =
  | Deleted of sentence_id list
  | Added of pre_sentence list
  | Equal of (sentence_id * pre_sentence) list

let same_tokens (s1 : sentence) (s2 : pre_sentence) = false

(* TODO improve diff strategy (insertions,etc) *)
let rec diff old_sentences new_sentences =
  match old_sentences, new_sentences with
  | [], [] -> []
  | [], new_sentences -> [Added new_sentences]
  | old_sentences, [] -> [Deleted (List.map (fun s -> s.id) old_sentences)]
    (* FIXME something special should be done when `Deleted` is applied to a parsing effect *)
  | old_sentence::old_sentences, new_sentence::new_sentences ->
    if same_tokens old_sentence new_sentence then
      Equal [(old_sentence.id,new_sentence)] :: diff old_sentences new_sentences
    else Deleted [old_sentence.id] :: Added [new_sentence] :: diff old_sentences new_sentences

let extract_string flag token = ""

let string_of_parsed_ast { tokens } = 
  (* TODO implement printer for vernac_entry *)
  "[" ^ String.concat "--" (List.map (extract_string false) tokens) ^ "]"

let string_of_diff_item doc = function
  | Deleted ids ->
       ids |> List.map (fun id -> Printf.sprintf "- (id: %d) %s" (Stateid.to_int id) (string_of_parsed_ast (Option.get (get_sentence doc id)).ast))
  | Added sentences ->
       sentences |> List.map (fun (s : pre_sentence) -> Printf.sprintf "+ %s" (string_of_parsed_ast s.ast))
  | Equal l ->
       l |> List.map (fun (id, (s : pre_sentence)) -> Printf.sprintf "= (id: %d) %s" (Stateid.to_int id) (string_of_parsed_ast s.ast))

let string_of_diff doc l =
  String.concat "\n" (List.flatten (List.map (string_of_diff_item doc) l))

(* let rec stream_tok n_tok acc str begin_line begin_char =
  let e = LStream.next (Pcoq.get_keyword_state ()) str in
  if Tok.(equal e EOI) then
    List.rev acc
  else
    stream_tok (n_tok+1) (e::acc) str begin_line begin_char *)

    (*
let parse_one_sentence stream ~st =
  let pa = Pcoq.Parsable.make stream in
  Vernacstate.Parser.parse st (Pvernac.main_entry (Some (Vernacinterp.get_default_proof_mode ()))) pa
  (* FIXME: handle proof mode correctly *)
  *)

(* let parse_one_sentence stream ~st =
  let entry = Pvernac.main_entry (Some (Synterp.get_default_proof_mode ())) in
  let pa = Pcoq.Parsable.make stream in
    Vernacstate.Synterp.unfreeze st;
    Pcoq.Entry.parse entry pa *)

(* let rec junk_sentence_end stream =
  match Stream.npeek () 2 stream with
  | ['.'; (' ' | '\t' | '\n' |'\r')] -> Stream.junk () stream
  | [] -> ()
  | _ ->  Stream.junk () stream; junk_sentence_end stream *)


(** TODO move inside ParsedDoc, remove set_parsing_errors *)
(* let rec parse_more synterp_state stream raw parsed errors =
  let handle_parse_error start msg =
    log @@ "handling parse error at " ^ string_of_int start;
    let stop = Stream.count stream in
    let parsing_error = { msg; start; stop; } in
    let errors = parsing_error :: errors in
    parse_more synterp_state stream raw parsed errors
  in
  let start = Stream.count stream in
  begin
    (* FIXME should we save lexer state? *)
    match parse_one_sentence stream ~st:synterp_state with
    | None (* EOI *) -> List.rev parsed, errors
    | Some ast ->
      let stop = Stream.count stream in
      log @@ "Parsed: " ^ (Pp.string_of_ppcmds @@ Ppvernac.pr_vernac ast);
      let begin_line, begin_char, end_char =
              match ast.loc with
              | Some lc -> lc.line_nb, lc.bp, lc.ep
              | None -> assert false
      in
      let str = String.sub (RawDocument.text raw) begin_char (end_char - begin_char) in
      let sstr = Stream.of_string str in
      let lex = CLexer.Lexer.tok_func sstr in
      let tokens = stream_tok 0 [] lex begin_line begin_char in
      begin
        try
          let entry = Synterp.synterp_control ast in
          let classification = Vernac_classifier.classify_vernac ast in
          let synterp_state = Vernacstate.Synterp.freeze () in
          let sentence = { ast = { ast = entry; classification; tokens }; start = begin_char; stop; synterp_state } in
          let parsed = sentence :: parsed in
          parse_more synterp_state stream raw parsed errors
        with exn ->
          let e, info = Exninfo.capture exn in
          let loc = Loc.get_loc @@ info in
          handle_parse_error start (loc, Pp.string_of_ppcmds @@ CErrors.iprint_no_report (e,info))
        end
    | exception (Stream.Error msg as exn) ->
      let loc = Loc.get_loc @@ Exninfo.info exn in
      junk_sentence_end stream;
      handle_parse_error start (loc,msg)
    | exception (CLexer.Error.E e as exn) -> (* May be more problematic to handle for the diff *)
      let loc = Loc.get_loc @@ Exninfo.info exn in
      junk_sentence_end stream;
      handle_parse_error start (loc,CLexer.Error.to_string e)
  end *)

(* let parse_more synterp_state stream raw =
  parse_more synterp_state stream raw [] [] *)

let patch_sentence parsed scheduler_state_before id ({ ast; start; stop; synterp_state } : pre_sentence) =
  log @@ "Patching sentence " ^ Stateid.to_string id;
  let old_sentence = SM.find id parsed.sentences_by_id in
  let scheduler_state_after, schedule =
    let ast = (ast.ast, ast.classification, synterp_state) in
    Scheduler.schedule_sentence (id,ast) scheduler_state_before parsed.schedule
  in
  let new_sentence = { old_sentence with ast; start; stop; scheduler_state_before; scheduler_state_after } in
  let sentences_by_id = SM.add id new_sentence parsed.sentences_by_id in
  let sentences_by_end = LM.remove old_sentence.stop parsed.sentences_by_end in
  let sentences_by_end = LM.add new_sentence.stop new_sentence sentences_by_end in
  { parsed with sentences_by_end; sentences_by_id; schedule }, scheduler_state_after

let invalidate top_edit parsed_doc new_sentences =
  (* Algo:
  We parse the new doc from the topmost edit to the bottom one.
  - If execution is required, we invalidate everything after the parsing
  effect. Then we diff the truncated zone and invalidate execution states.
  - If the previous doc contained a parsing effect in the editted zone, we also invalidate.
  Otherwise, we diff the editted zone.
  We invalidate dependents of changed/removed/added sentences (according to
  both/old/new graphs). When we have to invalidate a parsing effect state, we
  invalidate the parsing after it.
   *)
   (* TODO optimize by reducing the diff to the modified zone *)
   (*
  let text = RawDocument.text current.raw_doc in
  let len = String.length text in
  let stream = Stream.of_string text in
  let parsed_current = parse_more len stream current.parsed_doc () in
  *)
  let rec invalidate_diff parsed_doc scheduler_state invalid_ids = function
    | [] -> invalid_ids, parsed_doc
    | Equal s :: diffs ->
      let patch_sentence (parsed_doc,scheduler_state) (old_s,new_s) =
        patch_sentence parsed_doc scheduler_state old_s new_s
      in
      let parsed_doc, scheduler_state = List.fold_left patch_sentence (parsed_doc, scheduler_state) s in
      invalidate_diff parsed_doc scheduler_state invalid_ids diffs
    | Deleted ids :: diffs ->
      let invalid_ids = List.fold_left (fun ids id -> StateidSet.add id ids) invalid_ids ids in
      let parsed_doc = List.fold_left remove_sentence parsed_doc ids in
      (* FIXME update scheduler state, maybe invalidate after diff zone *)
      invalidate_diff parsed_doc scheduler_state invalid_ids diffs
    | Added new_sentences :: diffs ->
    (* FIXME could have side effect on the following, unchanged sentences *)
      let add_sentence (parsed_doc,scheduler_state) ({ start; stop; ast; synterp_state } : pre_sentence) =
        add_sentence parsed_doc start stop ast synterp_state scheduler_state
      in
      let parsed_doc, scheduler_state = List.fold_left add_sentence (parsed_doc,scheduler_state) new_sentences in
      invalidate_diff parsed_doc scheduler_state invalid_ids diffs
  in
  let (_,_synterp_state,scheduler_state) = state_at_pos parsed_doc top_edit in
  let old_sentences = sentences_after parsed_doc top_edit in
  let diff = diff old_sentences new_sentences in
  log @@ "diff:\n" ^ string_of_diff parsed_doc diff;
  invalidate_diff parsed_doc scheduler_state StateidSet.empty diff

(** Validate document when raw text has changed *)
let validate_document ({ parsed_loc; raw_doc; } as document) = 
  let (stop, parsing_state, _scheduler_state) = state_at_pos document parsed_loc in
  let text = RawDocument.text raw_doc in
  let stream = Stream.of_string text in
  while Stream.count stream < stop do Stream.junk stream done;
  log @@ Format.sprintf "Parsing more from pos %i" stop;
  let new_sentences, errors = [], [] (* parse_more parsing_state stream raw_doc *) (* TODO invalidate first *) in
  log @@ Format.sprintf "%i new sentences" (List.length new_sentences);
  let invalid_ids, document = invalidate (stop+1) document new_sentences in
  let document = set_parse_errors document errors in
  let parsed_loc = pos_at_end document in
  invalid_ids, { document with parsed_loc }

let create_document text =
  let raw_doc = RawDocument.create text in
    { parsed_loc = -1;
      raw_doc;
      sentences_by_id = SM.empty;
      sentences_by_end = LM.empty;
      parsing_errors_by_end = LM.empty;
      schedule = initial_schedule;
    }

let apply_text_edit document edit =
  let raw_doc, start = RawDocument.apply_text_edit document.raw_doc edit in
  let parsed_loc = min document.parsed_loc start in
  { document with raw_doc; parsed_loc }

let apply_text_edits document edits =
  let doc' = { document with raw_doc = document.raw_doc } in
  let doc = List.fold_left apply_text_edit doc' edits in
  doc, doc.parsed_loc

module Internal = struct

  let string_of_sentence sentence =
    Format.sprintf "[%s] (%i -> %i)" (Stateid.to_string sentence.id)
    (* (string_of_parsed_ast sentence.ast) *)
    sentence.start
    sentence.stop

end