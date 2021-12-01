(* user_command_generators.ml *)

(* generate User_command.t's, that is, either Signed_commands or
   Parties
*)

open Core_kernel
include User_command.Gen

(* using Precomputed_values depth introduces a cyclic dependency *)
let ledger_depth = 20

let parties_with_ledger () =
  let open Quickcheck.Let_syntax in
  let open Signature_lib in
  (* Need a fee payer keypair, and max_other_parties * 2 keypairs, because
     all the other parties might be new and their accounts not in the ledger;
     or they might all be old and in the ledger

     We'll put the fee payer account and max_other_parties accounts in the
     ledger, and have max_other_parties keypairs available for new accounts
  *)
  let num_keypairs = (Snapp_generators.max_other_parties * 2) + 1 in
  let keypairs = List.init num_keypairs ~f:(fun _ -> Keypair.create ()) in
  let keymap =
    List.fold keypairs ~init:Public_key.Compressed.Map.empty
      ~f:(fun map { public_key; private_key } ->
        let key = Public_key.compress public_key in
        Public_key.Compressed.Map.add_exn map ~key ~data:private_key)
  in
  let num_keypairs_in_ledger = Snapp_generators.max_other_parties + 1 in
  let keypairs_in_ledger = List.take keypairs num_keypairs_in_ledger in
  let account_ids =
    List.map keypairs_in_ledger ~f:(fun { public_key; _ } ->
        Account_id.create (Public_key.compress public_key) Token_id.default)
  in
  let%bind balances =
    (* min balance so that fee payer can at least pay the fee *)
    let min_balance =
      Mina_compile_config.minimum_user_command_fee |> Currency.Fee.to_int
      |> Currency.Balance.of_int
    in
    (* max balance to avoid overflow when adding deltas *)
    let max_balance =
      match
        Currency.Balance.add_amount min_balance
          (Currency.Amount.of_int 1_000_000_000_000)
      with
      | None ->
          failwith "parties_with_ledger: overflow for max_balance"
      | Some bal ->
          bal
    in
    Quickcheck.Generator.list_with_length num_keypairs_in_ledger
      (Currency.Balance.gen_incl min_balance max_balance)
  in
  let accounts =
    List.map2_exn account_ids balances ~f:(fun account_id balance ->
        Account.create account_id balance)
  in
  let fee_payer_keypair = List.hd_exn keypairs in
  let ledger = Ledger.create ~depth:ledger_depth () in
  List.iter2_exn account_ids accounts ~f:(fun acct_id acct ->
      match Ledger.get_or_create_account ledger acct_id acct with
      | Error err ->
          failwithf
            "parties: error adding account for account id: %s, error: %s@."
            (Account_id.to_yojson acct_id |> Yojson.Safe.to_string)
            (Error.to_string_hum err) ()
      | Ok (`Existed, _) ->
          failwithf "parties: account for account id already exists: %s@."
            (Account_id.to_yojson acct_id |> Yojson.Safe.to_string)
            ()
      | Ok (`Added, _) ->
          ()) ;
  let%bind protocol_state = Snapp_predicate.Protocol_state.gen in
  let%bind parties =
    Snapp_generators.gen_parties_from ~fee_payer_keypair ~keymap ~ledger
      ~protocol_state ()
  in
  (* include generated ledger in result *)
  return (User_command.Parties parties, ledger)

let sequence_parties_with_ledger ?length () =
  let open Quickcheck.Let_syntax in
  let%bind length =
    match length with
    | Some n ->
        return n
    | None ->
        Quickcheck.Generator.small_non_negative_int
  in
  let merge_ledger source_ledger target_ledger =
    (* add all accounts in source to target *)
    Ledger.iteri source_ledger ~f:(fun _ndx acct ->
        let acct_id = Account_id.create acct.public_key acct.token_id in
        match Ledger.get_or_create_account target_ledger acct_id acct with
        | Ok (`Added, _) ->
            ()
        | Ok (`Existed, _) ->
            failwith "Account already existed in target ledger"
        | Error err ->
            failwithf "Could not add account to target ledger: %s"
              (Error.to_string_hum err) ())
  in
  let init_ledger = Ledger.create ~depth:ledger_depth () in
  let rec go (partiess, acc_ledger) n =
    if n <= 0 then return (List.rev partiess, acc_ledger)
    else
      let%bind parties, ledger = parties_with_ledger () in
      let partiess' = parties :: partiess in
      merge_ledger ledger acc_ledger ;
      go (partiess', acc_ledger) (n - 1)
  in
  go ([], init_ledger) length
