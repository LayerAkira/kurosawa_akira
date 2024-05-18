use core::result::ResultTrait;
use poseidon::poseidon_hash_span;
use array::SpanTrait;
use array::ArrayTrait;
use serde::Serde;
use kurosawa_akira::utils::account::AccountABIDispatcherTrait;
use kurosawa_akira::utils::account::AccountABIDispatcher;
use starknet::ContractAddress;


// trait PoseidonHash<T> {
//     fn get_poseidon_hash(self: T) -> felt252;
// }

// impl PoseidonHashImpl<T, impl TSerde: Serde<T>, impl TDestruct: Destruct<T>> of PoseidonHash<T> {
//     fn get_poseidon_hash(self: T) -> felt252 {
//         let mut serialized: Array<felt252> = ArrayTrait::new();
//         Serde::<T>::serialize(@self, ref serialized);
//         let hashed_key: felt252 = poseidon_hash_span(serialized.span());
//         hashed_key
//     }
// }

fn check_sign(account: ContractAddress, hash: felt252, sign: (felt252, felt252)) -> bool {
    let mut calldata = ArrayTrait::new();
    let (r,s) = sign;
    calldata.append(r); calldata.append(s);
    let res = AccountABIDispatcher{contract_address:account}.is_valid_signature(hash, calldata);
    return res == 'VALID';
}
