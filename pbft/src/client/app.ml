open Core_kernel
open Async_kernel
open Incr_dom
open Rpcs

module Model = struct
  type t = { input_text : string; value : int } [@@deriving fields, equal]

  let cutoff = equal
end

module State = struct
  type t = unit
end

module Action = struct
  type t = Apply of Interface.Data.t | Submit | Update_add_input of string
  [@@deriving sexp]
end

let data_r, data_w = Pipe.create ()

let operation_r, operation_w = Pipe.create ()

let initial_model = Model.{ input_text = ""; value = 0 }

let on_startup ~schedule_action _model =
  don't_wait_for
    (Pipe.iter_without_pushback data_r ~f:(fun data ->
         schedule_action (Action.Apply data)));
  Deferred.unit

let create (model : Model.t Incr.t) ~old_model:_ ~inject =
  let open Incr.Let_syntax in
  let%map apply_action =
    let%map model = model in
    fun action _state ~schedule_action:_ ->
      match action with
      | Action.Apply data -> Model.{ model with value = data }
      | Submit ->
          let text = model.input_text in
          printf "Text val: %s\n" text;
          Option.iter (int_of_string_opt text) ~f:(fun x ->
              printf "Submitting\n";
              Pipe.write_without_pushback operation_w
                (Interface.Operation.Add x));
          model
      | Update_add_input s ->
          printf "Input updated to %s\n" s;
          Model.{ model with input_text = s }
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