use core::traits::Into;
use starknet::ContractAddress;
use serde::Serde;
use array::SpanTrait;
use starknet::{get_block_timestamp};
use kurosawa_akira::utils::common::{min,DisplayContractAddress};


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Hash)]
struct GasFee {
    gas_per_action: u32,
    fee_token: ContractAddress,
    max_gas_price: u256,
    conversion_rate: (u256, u256),
}

#[derive(Copy, Drop, Serde)]
struct GasContext { 
    gas_price:u256,  // represent gas price that mirrors blockhain
    cur_gas_per_action:u32 // amount of steps required to settle 1 gas trading action
}


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq,Hash)]
struct FixedFee {
    recipient: ContractAddress,
    maker_pbips: u32,
    taker_pbips: u32,
}

fn get_feeable_qty(fixed_fee: FixedFee, feeable_qty: u256, is_maker:bool) -> u256 {
    let pbips = if is_maker {fixed_fee.maker_pbips} else {fixed_fee.taker_pbips};
    if pbips == 0 { return 0;}
    return (feeable_qty * pbips.into() - 1) / 1_000_000 + 1;
}

fn get_gas_fee_and_coin(gas_fee: GasFee, native_token:ContractAddress, times:u16, gas_ctx:GasContext) -> (u256, ContractAddress) {
    if gas_ctx.gas_price == 0 { return (0, native_token);}
    if gas_fee.gas_per_action == 0 { return (0, native_token);}
    assert!(gas_fee.max_gas_price >= gas_ctx.gas_price, "Failed: max_gas_price ({}) >= cur_gas_price ({})", gas_fee.max_gas_price, gas_ctx.gas_price);
    assert!(gas_fee.gas_per_action >= gas_ctx.cur_gas_per_action, "Failed: gas_per_action ({}) >= cur_gas_per_action ({})", gas_fee.gas_per_action, gas_ctx.cur_gas_per_action);
    
    let spend_native = gas_ctx.cur_gas_per_action.into() * gas_ctx.gas_price;
    
    if gas_fee.fee_token == native_token {
        return (spend_native, native_token);
    }

    let (r0, r1) = gas_fee.conversion_rate;
    let spend_converted = spend_native * r1 / r0;
    return (spend_converted * times.into(), gas_fee.fee_token);
}