use kurosawa_akira::ExchangeEventStructures::Events::DepositEvent::Deposit;
use kurosawa_akira::ExchangeEventStructures::Events::WithdrawEvent::Withdraw;
use kurosawa_akira::ExchangeEventStructures::Events::TradeEvent::Trade;
use kurosawa_akira::ExchangeEventStructures::Events::Order::Order;
use poseidon::poseidon_hash_span;
use array::SpanTrait;
use array::ArrayTrait;
use serde::Serde;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;
use kurosawa_akira::utils::account::AccountABIDispatcherTrait;
use kurosawa_akira::utils::account::AccountABIDispatcher;
use starknet::ContractAddress;

trait Pending<T> {
    fn set_pending(self: T, ref state: ContractState) -> felt252;
}

trait Zeroable<T> {
    fn is_zero(self: T) -> bool;
    fn zero(self: T) -> T;
}

trait PoseidonHash<T> {
    fn get_poseidon_hash(self: T) -> felt252;
}

impl PoseidonHashImpl<T, impl TSerde: Serde<T>, impl TDestruct: Destruct<T>> of PoseidonHash<T> {
    fn get_poseidon_hash(self: T) -> felt252 {
        let mut serialized: Array<felt252> = ArrayTrait::new();
        Serde::<T>::serialize(@self, ref serialized);
        let hashed_key: felt252 = poseidon_hash_span(serialized.span());
        hashed_key
    }
}

fn check_sign(account: ContractAddress, hash: felt252, sign: (felt252, felt252)) {
    let mut sign_arr = ArrayTrait::new();
    let (x, y) = sign;
    sign_arr.append(x);
    sign_arr.append(y);
    AccountABIDispatcher { contract_address: account }.is_valid_signature(hash, sign_arr);
}