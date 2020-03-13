open Core_kernel
open Async_rpc_kernel

module Request = struct
  (* Optimization: send a digest instead of the entire operation *)
  type t = {
    leader_number : int;
    view : int;
    message : Client_to_server_rpcs.Request.t;
    sequence_number : int;
  }
  [@@deriving bin_io]

  let create ~leader_number ~view ~message ~sequence_number =
    { leader_number; view; message; sequence_number }
end

let rpc =
  Rpc.One_way.create ~name:"preprepare-rpc" ~version:1 ~bin_msg:Request.bin_t