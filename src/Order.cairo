use core::traits::Into;
use starknet::ContractAddress;
use serde::Serde;
use poseidon::poseidon_hash_span;
use array::ArrayTrait;
use array::SpanTrait;

// TODO use this once all stuff rewritten in components
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct GasFee {
    gas_per_action: u32,
    fee_token: ContractAddress,
    max_gas_price: u256,
    conversion_rate: (u256, u256),
}




#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct FixedFee {
    recipient: ContractAddress,
    maker_pbips: u32,
    taker_pbips: u32
}


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct OrderFee {
    trade_fee: FixedFee,
    router_fee: FixedFee,
    gas_fee: GasFee,
}



#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct OrderFlags {
    full_fill_only: bool, 
    best_level_only: bool,
    post_only: bool,
    is_sell_side: bool,
    is_market_order: bool,
    to_safe_book: bool
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Order {
    maker: ContractAddress,
    price: u256,
    quantity: u256,
    ticker:(ContractAddress,ContractAddress),
    fee: OrderFee,
    number_of_swaps_allowed: u8,
    salt: felt252,
    nonce: u32,
    flags: OrderFlags,
    router_signer: ContractAddress,
    base_asset:u256
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SignedOrder {
    order: Order,
    sign: (felt252, felt252),
    router_sign: (felt252,felt252)
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct OrderTradeInfo {
    filled_amount: u256,
    last_traded_px: u256,
    num_trades_happened: u8
}


fn validate_maker_order(order: Order, orders_trade_info:OrderTradeInfo, nonce:u32, settlement_price:u256) -> (u256,u256) {
    let remaining = order.quantity - orders_trade_info.filled_amount;
    assert(!order.flags.is_market_order, 'WRONG_MARKET_TYPE');
    assert(remaining > 0, 'MAKER_ALREADY_FILLED');
    assert(order.nonce >= nonce, 'OLD_NONCE');
    
    if order.flags.post_only {
        assert(!order.flags.best_level_only && !order.flags.full_fill_only, 'WRONG_MAKER_FLAGS');
        return (order.quantity - orders_trade_info.filled_amount, order.price);
    }
    assert(!order.flags.full_fill_only, 'WRONG_MAKER_FLAG');

    if orders_trade_info.filled_amount > 0 {
        return (remaining,orders_trade_info.last_traded_px);
    }
    return (remaining, order.price);
}


fn validate_taker_order(order: Order, orders_trade_info:OrderTradeInfo, nonce:u32, settlement_price:u256) -> u256 {
    let remaining = order.quantity - orders_trade_info.filled_amount;
    assert(order.number_of_swaps_allowed > orders_trade_info.num_trades_happened, 'HIT_SWAPS_ALLOWED');
    assert(!order.flags.post_only, 'WRONG_TAKER_FLAG');
    assert(remaining > 0, 'MAKER_ALREADY_FILLED');
    assert(order.nonce >= nonce, 'OLD_NONCE');
    if !order.flags.is_sell_side {
        assert(order.price <= settlement_price, 'BUY_PROTECTION_PRICE_FAILED');
    } else {
        assert(order.price >= settlement_price, 'SELL_PROTECTION_PRICE_FAILED');
    }
    
        if orders_trade_info.filled_amount > 0 {
            if !order.flags.is_sell_side {
                assert(orders_trade_info.last_traded_px <= settlement_price, 'BUY_PARTIAL_FILL_ERR');
            } 
            else {
                assert(orders_trade_info.last_traded_px >= settlement_price, 'SELL_PARTIAL_FILL_ERR');
            }
            if order.flags.best_level_only {
                assert(orders_trade_info.last_traded_px == settlement_price, 'BEST_LVL_ONLY',);
            }
            
            return remaining;
        }
    return order.quantity;
    // FULL_FILL_ONLY_FLAG checked by user of this func and sign too
}


fn get_feeable_qty(fixed_fee: FixedFee, feeable_qty: u256,is_maker:bool) -> u256 {
    let pbips = if is_maker {fixed_fee.maker_pbips} else {fixed_fee.taker_pbips};
    if pbips == 0 { return 0;}
    return (feeable_qty * pbips.into() - 1) / 1_000_000 + 1;
}

fn get_limit_px(maker_order:Order, maker_fill_info:OrderTradeInfo) -> (u256, u256){
    let settle_px = if maker_fill_info.filled_amount > 0 {maker_fill_info.last_traded_px} else {maker_order.price};
    return (settle_px, maker_order.quantity - maker_fill_info.filled_amount); 
}

fn do_taker_price_checks(taker_order:Order, settle_px:u256, taker_fill_info:OrderTradeInfo)->u256 {
    if !taker_order.flags.is_sell_side { assert(taker_order.price <= settle_px, 'BUY_PROTECTION_PRICE_FAILED');}
    else { assert(taker_order.price >= settle_px, 'SELL_PROTECTION_PRICE_FAILED'); }

    if taker_fill_info.filled_amount > 0 {
        if taker_order.flags.best_level_only { assert(taker_fill_info.last_traded_px == settle_px , 'BEST_LVL_ONLY',);}
        else {
            if !taker_order.flags.is_sell_side { assert(taker_fill_info.last_traded_px <= settle_px, 'BUY_PARTIAL_FILL_ERR');} 
            else { assert(taker_fill_info.last_traded_px >= settle_px, 'SELL_PARTIAL_FILL_ERR');}
        }
    }
    let rem = taker_order.quantity - taker_fill_info.filled_amount;
    assert(rem > 0, 'FILLED_TAKER_ORDER');
    return rem;
}

fn do_maker_checks(maker_order:Order, maker_fill_info:OrderTradeInfo,nonce:u32)-> (u256, u256) {
    assert(!maker_order.flags.is_market_order, 'WRONG_MARKET_TYPE');
    let remaining = maker_order.quantity - maker_fill_info.filled_amount;
    assert(remaining > 0, 'MAKER_ALREADY_FILLED');
    assert(maker_order.nonce >= nonce,'OLD_MAKER_NONCE');
    assert(!maker_order.flags.full_fill_only, 'WRONG_MAKER_FLAG');

    if maker_order.flags.post_only {
        assert(!maker_order.flags.best_level_only && !maker_order.flags.full_fill_only, 'WRONG_MAKER_FLAGS');
    }
    let settle_px = if maker_fill_info.filled_amount > 0 {maker_fill_info.last_traded_px} else {maker_order.price};
    return (settle_px, remaining); 
}


fn get_gas_fee_and_coin(gas_fee: GasFee, cur_gas_price: u256, native_token:ContractAddress) -> (u256, ContractAddress) {
    if cur_gas_price == 0 { return (0, native_token);}
    if gas_fee.gas_per_action == 0 { return (0, native_token);}
    assert(gas_fee.max_gas_price >= cur_gas_price, 'gas_prc <-= user stated prc');
    let spend_native = gas_fee.gas_per_action.into() * cur_gas_price;
    
    if gas_fee.fee_token == native_token {
        return (spend_native, native_token);
    }

    let (r0, r1) = gas_fee.conversion_rate;
    let spend_converted = spend_native * r1 / r0;
    return (spend_converted, gas_fee.fee_token);
}
