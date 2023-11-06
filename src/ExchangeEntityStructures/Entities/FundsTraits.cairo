use kurosawa_akira::ExchangeEntityStructures::Entities::DepositEntity::Deposit;
use kurosawa_akira::ExchangeEntityStructures::Entities::WithdrawEntity::Withdraw;
use kurosawa_akira::ExchangeEntityStructures::Entities::TradeEntity::Trade;
use kurosawa_akira::ExchangeEntityStructures::Entities::Order::Order;
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
    fn request_cancellation_pending(self: T, ref state: ContractState);
    fn cancel_pending(self: T, ref state: ContractState);
}

trait OnchainWithdraw<T> {
    // fn request_onchain_withdraw(self: T, ref state: ContractState);
    fn make_onchain_withdraw(self: T, ref state: ContractState);
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
    let selector =
        0x028420862938116cb3bbdbedee07451ccc54d4e9412dbef71142ad1980a30941; // is_valid_signature
    let (x, y) = sign;
    let mut calldata = ArrayTrait::new();
    calldata.append(hash);
    calldata.append(2);
    calldata.append(x);
    calldata.append(y);
    let mut res = starknet::call_contract_syscall(account, selector, calldata.span());
}
