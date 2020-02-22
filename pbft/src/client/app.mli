open Async_kernel
open Rpcs

val data_w : Interface.Data.t Pipe.Writer.t

val operation_r : Interface.Operation.t Pipe.Reader.t

include Incr_dom.App_intf.S

val initial_model : Model.t
