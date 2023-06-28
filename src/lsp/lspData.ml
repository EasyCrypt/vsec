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
open Sexplib.Std

module Uri = struct

  include Uri

  let t_of_yojson = function
  | `String str -> Uri.of_string str
  | _ -> raise (Invalid_argument "t_of_yojson")

  let yojson_of_t uri = `String (Uri.to_string uri)

  let of_fname fname =
    Uri.make ~scheme:"file" ~path:fname ()

end

module Position = struct
  
  type t = { line : int; character : int; } [@@deriving sexp, yojson]

  let compare pos1 pos2 =
    match Int.compare pos1.line pos2.line with
    | 0 -> Int.compare pos1.character pos2.character
    | x -> x

  let to_string pos = Format.sprintf "(%i,%i)" pos.line pos.character

end

module Range = struct

  type t = {
    start : Position.t;
    end_ : Position.t; [@key "end"]
  } [@@deriving sexp, yojson]

  let included ~in_ { start; end_ } =
    let (<=) x y = Position.compare x y <= 0 in
    in_.start <= start && end_ <= in_.end_

end 

module CompletionItem = struct 

  type t = {
    label : string;
    detail : string option [@yojson.option];
    documentation : string option [@yojson.option];
  } [@@deriving yojson]

end

module Severity = struct

  type t = 
  | Debug
  | Info
  | Notice
  | Warning
  | Error
  [@@deriving sexp, yojson]

  let yojson_of_t = function
  | Error -> `Int 1
  | Warning -> `Int 2
  | Debug | Info | Notice -> `Int 3

end

module Diagnostic = struct

  type t = {
    range : Range.t;
    message : string;
    severity : Severity.t;
  } [@@deriving sexp, yojson]

end

type query_result =
  { id : string;
    name : string;
    statement : string;
  } [@@deriving yojson]

type notification =
  | QueryResultNotification of query_result

module Error = struct

  let parseError = -32700
  let invalidRequest = -32600
  let methodNotFound = -32601
  let invalidParams = -32602
  let internalError = -32603
  let jsonrpcReservedErrorRangeStart = -32099
  let serverNotInitialized = -32002
  let unknownErrorCode = -32001
  let lspReservedErrorRangeStart = -32899
  let requestFailed = -32803
  let serverCancelled = -32802
  let contentModified = -32801
  let requestCancelled = -32800
  let lspReservedErrorRangeEnd = -32800

end

module ServerCapabilities = struct

  type textDocumentSyncKind =
  | None
  | Full
  | Incremental

  let yojson_of_textDocumentSyncKind = function
  | None -> `Int 0
  | Full -> `Int 1
  | Incremental -> `Int 2

  let textDocumentSyncKind_of_yojson = function
  | `Int 0 -> None
  | `Int 1 -> Full
  | `Int 2 -> Incremental
  | _ -> Yojson.json_error "invalid value"

  type completionItem = {
    labelDetailsSupport : bool option [@yojson.option];
  } [@@deriving yojson]

  type completionOptions = {
    triggerCharacters : string list option [@yojson.option];
    allCommitCharacters : string list option [@yojson.option];
    resolveProvider : bool option [@yojson.option];
    completionItem : completionItem option [@yojson.option];
  } [@@deriving yojson]

  type t = {
    textDocumentSync : textDocumentSyncKind;
    completionProvider : completionOptions;
    hoverProvider : bool;
  } [@@deriving yojson]

end

module ServerInfo = struct

    type t = {
      name: string; 
      version: string; 
    } [@@deriving yojson]

end

module Hover = struct 
    
  type t = {
    contents: string
  } [@@deriving yojson]

end

module ConfigurationItem = struct

  type t = {
	  scopeUri: string option; [@yojson option]
	  section: string option; [@yojson option]
  } [@@deriving yojson]

end

module Settings = struct

  module DelegationMode = struct

  type t = 
    | None
    | Skip 
    | Delegate 

  let yojson_of_t = function
  | None -> `String "None"
  | Skip -> `String "Skip"
  | Delegate -> `String "Delegate"

  let t_of_yojson = function
  | `String "None" -> None
  | `String "Skip" -> Skip
  | `String "Delegate" -> Delegate
  | _ -> Yojson.json_error "invalid value"

  end
  
  module Mode = struct

    type t =
    | Continuous 
    | Manual
    [@@deriving yojson]
      
    let yojson_of_t = function
    | Manual -> `Int 0
    | Continuous -> `Int 1
  
    let t_of_yojson = function
    | `Int 0 -> Manual
    | `Int 1 -> Continuous
    | _ -> Yojson.json_error @@ "invalid value "
  
  end

  module Proof = struct

    type t = {
      delegation: DelegationMode.t;
      workers: int option;
      mode: Mode.t;
    } [@@deriving yojson] [@@yojson.allow_extra_fields]

  end

  type t = {
    proof: Proof.t;
  } [@@deriving yojson] [@@yojson.allow_extra_fields]

end

module TextDocumentItem = struct

  type t = {
    uri: Uri.t;
    languageId: string;
    version: int;
    text: string;
  } [@@deriving yojson]

end

module TextDocumentIdentifier = struct

  type t = {
    uri: Uri.t;
  } [@@deriving yojson]

end

module VersionedTextDocumentIdentifier = struct

  type t = {
    uri: Uri.t;
    version: int;
  } [@@deriving yojson]

end

module TextDocumentPositionParams = struct

  type t = {
    textDocument: TextDocumentIdentifier.t;
    position: Position.t;
  } [@@deriving yojson]

end

module TextDocumentContentChangeEvent = struct

  type t = {
    range : Range.t option; [@yojson.option]
    rangeLength : int option; [@yojson.option]
    text : string;
  } [@@deriving yojson]
  
end
