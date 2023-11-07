use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::FeeLogic::FixedFee::FixedFee;
use kurosawa_akira::FeeLogic::GasFee::GasFee;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct OrderFee {
    trade_fee: FixedFee,
    router_fee: FixedFee,
    gas_fee: GasFee,
}
