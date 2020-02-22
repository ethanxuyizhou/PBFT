open Core_kernel
open Async_kernel
open Async_js
open Incr_dom
open Rpcs

let () =
  Async_js.init ();
  don't_wait_for
    (let%bind connection =
       printf "Establishing connection\n";
       Rpc.Connection.client_exn ~uri:(Uri.of_string "ws://localhost") ()
     in
     let%map r, _ =
       Rpc.Pipe_rpc.dispatch_exn App_to_client_rpcs.data_rpc connection ()
     in
     don't_wait_for
       (Pipe.iter_without_pushback App.operation_r ~f:(fun operation ->
            printf "Sending operation\n";
            let (_ : unit Or_error.t) =
              Rpc.One_way.dispatch App_to_client_rpcs.operation_rpc connection
                operation
            in
            ()));
     don't_wait_for (Pipe.transfer r App.data_w ~f:Fn.id);
     Start_app.start
       (module App)
       ~bind_to_element_with_id:"app" ~initial_model:App.initial_model)
