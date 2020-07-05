open! Core_kernel
open! Async_kernel
open Rpcs
open Bonsai_web.Future

module Model = struct
  type t = { input_text : string; value : Interface.Data.t }
  [@@deriving sexp, fields, equal]

  let default = { input_text = ""; value = 0 }
end

module Action = struct
  type t =
    | Update_value of Interface.Data.t
    | Submit
    | Update_input_text of string
  [@@deriving sexp]
end

let build data ((model : Model.t), apply_action) =
  let add_button =
    Vdom.Node.button
      [ Vdom.Attr.on_click (fun _ev -> apply_action Action.Submit) ]
      [ Vdom.Node.text "Add" ]
  in
  let text_box =
    Vdom.Node.input
      [
        Vdom.Attr.type_ "text";
        Vdom.Attr.string_property "value" (Int.to_string data);
        Vdom.Attr.on_input (fun _ev text ->
            apply_action (Action.Update_input_text text));
      ]
      []
  in
  let value = Vdom.Node.text (string_of_int model.value) in
  Vdom.Node.body [] [ text_box; add_button; value ]

let component ~data ~send_request =
  let open Bonsai.Let_syntax in
  let%sub state =
    Bonsai.state_machine0 [%here]
      (module Model)
      (module Action)
      ~default_model:Model.default
      ~apply_action:(fun ~inject:_ ~schedule_event:_ model action ->
        match action with
        | Action.Update_value data -> { model with value = data }
        | Submit ->
            ( match
                Or_error.try_with (fun () -> Int.of_string model.input_text)
              with
            | Ok operation -> send_request (Interface.Operation.Add operation)
            | Error (_ : Error.t) -> () );
            model
        | Update_input_text s -> { model with input_text = s })
  in
  return
    (let%map state = state and data = data in
     build data state)
