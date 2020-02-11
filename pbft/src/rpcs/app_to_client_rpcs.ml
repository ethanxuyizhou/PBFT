open Core_kernel
open Async_rpc_kernel
open Interface

(* This is a particular messaging paradigm designed to use rpc
   as a tool for bi-directional, asynchronous communication. Client uses one-way
   rpcs to send requests to server. Since the messaging is asynchronous, client
   needs to send server a [Hello.t] to get back a pipe of Response.t. 
*)

module Request = struct
  type t = Operation.t [@@deriving bin_io]
end

module Hello = struct
  type t = unit [@@deriving bin_io]
end

module Response = struct
  type t = Data.t [@@deriving bin_io]
end

let operation_rpc =
  Rpc.One_way.create ~name:"operation-rpc" ~version:1 ~bin_msg:Request.bin_t

let data_rpc =
  Rpc.Pipe_rpc.create ~name:"data-rpc" ~version:1 ~bin_query:Hello.bin_t
    ~bin_response:Response.bin_t ~bin_error:Error.bin_t ()
