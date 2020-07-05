open! Core_kernel
open! Async_kernel
open Rpcs
open Bonsai_web.Future

val component : data:(Interface.Data.t Bonsai.Value.t) -> send_request:(Interface.Operation.t -> unit) -> Vdom.Node.t Bonsai.Computation.t 
