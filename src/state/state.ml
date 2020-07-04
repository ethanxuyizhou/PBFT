open! Core
open! Async
open Rpcs

type t = {
  mutable sequence_num : int;
  mutable current_view : int;
  mutable client_log : Client_to_server_rpcs.Operation.Set.t;
  preprepare_log : Preprepare_log.t;
  prepare_log : Prepare_log.t;
  commit_log : Commit_log.t;
  commit_queue : Queue.t;
  client_to_latest_timestamp : Time.t String.Table.t;
  mutable last_committed_seq_num : int;
  mutable timer : Timer.t;
  mutable checkpoint_log : Checkpoint_log.t;
  mutable running : bool;
  mutable view_change_log : View_change_log.t;
}

let create () =
  let client_log = Client_to_server_rpcs.Operation.Set.empty in
  let preprepare_log = Preprepare_log.create () in
  let prepare_log = Prepare_log.create () in
  let commit_log = Commit_log.create () in
  let commit_queue = Queue.create () in
  let client_to_latest_timestamp = String.Map.empty in
  let timer = Timer.create () in
  let checkpoint_log = Checkpoint_log.create () in
  let last_stable_checkpoint =
    { last_sequence_number = 0; state = Interface.Data.init () }
  in
  let view_change_log = View_change_log.create () in
  {
    seq_num = 0;
    current_view = 0;
    client_log;
    preprepare_log;
    prepare_log;
    commit_log;
    commit_queue;
    client_to_latest_timestamp;
    last_committed_seq_num = 0;
    timer;
    checkpoint_log;
    running = true;
    view_change_log;
  }
