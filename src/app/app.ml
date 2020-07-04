open Core_kernel
open Async_kernel
open Async_js
open Incr_dom
open Rpcs

module Model = struct
  type t = {
    input_text : string;
    value : int;
    operation_reader : Interface.Operation.t Pipe.Reader.t;
    operation_writer : Interface.Operation.t Pipe.Writer.t;
  }
  [@@deriving fields]

  let cutoff t1 t2 =
    String.equal t1.input_text t2.input_text && Int.equal t1.value t2.value
end

module State = struct
  type t = unit
end

module Action = struct
  type t = Apply of Interface.Data.t | Submit | Update_add_input of string
  [@@deriving sexp]
end

let on_startup ~schedule_action (model : Model.t) =
  let%bind connection =
    Rpc.Connection.client_exn ~uri:(Uri.of_string "ws://localhost") ()
  in
  let%bind data_r, _ =
    Rpc.Pipe_rpc.dispatch_exn App_to_client_rpcs.data_rpc connection ()
  in
  don't_wait_for
    (Pipe.iter_without_pushback data_r ~f:(fun data ->
         schedule_action (Action.Apply data)));
  don't_wait_for
    (Pipe.iter_without_pushback model.operation_reader ~f:(fun operation ->
         Rpc.One_way.dispatch_exn App_to_client_rpcs.operation_rpc connection
           operation));
  Deferred.unit

let initial_model =
  let operation_reader, operation_writer = Pipe.create () in
  { Model.input_text = ""; value = 0; operation_reader; operation_writer }

let create (model : Model.t Incr.t) ~old_model:_ ~inject =
  let open Incr.Let_syntax in
  let%map apply_action =
    let%map model = model in
    fun action _state ~schedule_action:_ ->
      match action with
      | Action.Apply data -> Model.{ model with value = data }
      | Submit ->
          let text = model.input_text in
          Option.iter (int_of_string_opt text) ~f:(fun x ->
              Pipe.write_without_pushback model.operation_writer
                (Interface.Operation.Add x));
          model
      | Update_add_input s -> Model.{ model with input_text = s }
  and model = model
  and view =
    let open Vdom in
    let%bind add_input =
      let%map input_text = model >>| Model.input_text in
      Node.input
        [
          Attr.type_ "text";
          Attr.string_property "value" input_text;
          Attr.on_input (fun _ev text -> inject (Action.Update_add_input text));
        ]
        []
    in
    let add_button =
      Node.button
        [ Attr.on_click (fun _ev -> inject Action.Submit) ]
        [ Node.text "Add" ]
    in
    let%map value =
      let%map value = model >>| Model.value in
      Node.text (string_of_int value)
    in
    Node.body [] [ add_input; add_button; value ]
  in
  Component.create ~apply_action model view
