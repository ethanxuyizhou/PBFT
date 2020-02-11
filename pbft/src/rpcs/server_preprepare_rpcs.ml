open Core_kernel
open Async_rpc_kernel
open Interface

module Request = struct
  (* Optimization: send a digest instead of the entire operation *)
  type t = {
    view : int;
    message : Client_to_server_rpcs.Request.t;
    sequence_number : int;
  }
  [@@deriving bin_io]
end

let rpc =
  Rpc.One_way.create ~name:"preprepare-rpc" ~version:1 ~bin_msg:Request.bin_t
