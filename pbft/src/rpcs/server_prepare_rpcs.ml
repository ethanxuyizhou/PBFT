open Core_kernel
open Async_rpc_kernel

module Request = struct
  type t = {
    replica_number : int;
    view : int;
    message : Client_to_server_rpcs.Request.t;
    sequence_number : int;
  }
  [@@deriving bin_io]
end

let rpc =
  Rpc.One_way.create ~name:"prepare-rpc" ~version:1 ~bin_msg:Request.bin_t
