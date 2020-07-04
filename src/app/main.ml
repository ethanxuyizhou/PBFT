open! Core_kernel
open! Async_kernel
open Incr_dom

let () =
  Async_js.init ();
    (Start_app.start
       (module App)
       ~bind_to_element_with_id:"app" ~initial_model:App.initial_model)
