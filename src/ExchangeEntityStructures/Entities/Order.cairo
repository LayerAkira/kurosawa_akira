use starknet::ContractAddress;
use serde::Serde;
use poseidon::poseidon_hash_span;
use array::ArrayTrait;
use array::SpanTrait;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::check_sign;
use kurosawa_akira::FeeLogic::OrderFee::OrderFee;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Order {
    price: u256,
    quantity: u256,
    maker: ContractAddress,
    full_fill_only: bool,
    best_level_only: bool,
    post_only: bool,
    side: bool,
    qty_address: ContractAddress,
    price_address: ContractAddress,
    order_type: bool,
    fee: OrderFee,
    number_of_swaps_allowed: u256,
    salt: felt252,
    to_safe_book: bool,
    nonce: u256,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SignedOrder {
    order: Order,
    sign: (felt252, felt252),
}
