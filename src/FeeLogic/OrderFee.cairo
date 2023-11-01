use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::FeeLogic::FixedFee::FixedFee;
use kurosawa_akira::FeeLogic::FixedFee::apply_fixed_fee_involved;
use kurosawa_akira::FeeLogic::GasFee::GasFee;
use kurosawa_akira::FeeLogic::GasFee::validate_and_apply_gas_fee;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_cur_gas_price_read;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct OrderFee {
    trade_fee: FixedFee,
    router_fee: FixedFee,
    gas_fee: GasFee,
}


fn apply_order_fee(
    ref state: ContractState,
    user: ContractAddress,
    order_fee: OrderFee,
    feeable_qty: u256,
    fee_token: ContractAddress,
    is_maker: bool
) {
    assert(order_fee.trade_fee.fee_token == fee_token, 'wrong fee token');
    apply_fixed_fee_involved(ref state, user, order_fee.trade_fee, feeable_qty);
    if !order_fee.router_fee.is_zero() {
        assert(order_fee.router_fee.fee_token == fee_token, 'wrong fee token');
        apply_fixed_fee_involved(ref state, user, order_fee.router_fee, feeable_qty);
    }
    if (!is_maker & !order_fee.gas_fee.is_zero()) {
        validate_and_apply_gas_fee(
            ref state, user, order_fee.gas_fee, _cur_gas_price_read(ref state)
        );
    }
}
