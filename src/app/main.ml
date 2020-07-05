open! Core_kernel
open! Async_kernel
open! Async_js
open Bonsai_web.Future
open Rpcs

let refresh_data ~connection ~data =
   let%bind data_pipe, _ =
    Rpc.Pipe_rpc.dispatch_exn App_to_client_rpcs.data_rpc connection ()
  in
  Pipe.iter_without_pushback data_pipe ~f:(fun data' ->
      Bonsai.Var.set data data')


let run () = 
  Async_js.init ();
  let%bind connection =
    Rpc.Connection.client_exn ~uri:(Uri.of_string "ws://localhost") ()
  in
  let data = Bonsai.Var.create 0 in
  don't_wait_for (refresh_data ~data ~connection);
   let send_request operation =
    Rpc.One_way.dispatch_exn App_to_client_rpcs.operation_rpc connection operation in
  let (_ : _ Start.Handle.t) = 
    Start.start
      Start.Result_spec.just_the_view
      ~bind_to_element_with_id:"app"
      (App.component
         ~data:(Bonsai.Var.value data)
         ~send_request) in 
  return ()

let () = 
  don't_wait_for (run ())
