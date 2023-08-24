use kurosawa_akira::ExchangeEventStructures::Events::DepositEvent::Deposit;
use kurosawa_akira::ExchangeEventStructures::Events::WithdrawEvent::Withdraw;
use kurosawa_akira::ExchangeEventStructures::Events::TradeEvent::Trade;
use kurosawa_akira::ExchangeEventStructures::Events::Order::Order;
use poseidon::poseidon_hash_span;
use array::SpanTrait;
use array::ArrayTrait;
use serde::Serde;

trait Pending<T> {
    fn set_pending(self: T);
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
