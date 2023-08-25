use starknet::ContractAddress;
use serde::Serde;
use poseidon::poseidon_hash_span;
use array::ArrayTrait;
use array::SpanTrait;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_filled_amount_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;
use kurosawa_akira::ExchangeEventStructures::Events::FundsTraits::check_sign;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Order {
    price: u256,
    quantity: u256,
    maker: ContractAddress,
    created_at: u256,
    order_id: u256,
    full_fill_only: bool,
    best_level_only: bool,
    post_only: bool,
    side: bool,
    status: u8,
    qty_address: ContractAddress,
    price_address: ContractAddress,
    order_type: bool,
}

#[external]
fn get_order_hash(key: Order) -> felt252 {
    let mut serialized: Array<felt252> = ArrayTrait::new();
    Serde::<Order>::serialize(@key, ref serialized);
    let hashed_key: felt252 = poseidon_hash_span(serialized.span());
    hashed_key
}

fn validate_order(order: Order, order_hash: felt252, sign: (felt252, felt252), ref state: ContractState) -> u256 {
    check_sign(order.maker, order_hash, sign);
    order.quantity - _filled_amount_read(ref state, order_hash)
}
