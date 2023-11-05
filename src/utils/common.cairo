use serde::Serde;
use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct ChainCtx {
    caller: ContractAddress,
    value: u256,
    block: u64,
    timestamp: u64,
    gas_price: u256,
    tx_index: u256,
}
