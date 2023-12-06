use starknet::ContractAddress;
use serde::Serde;
use poseidon::poseidon_hash_span;
use array::ArrayTrait;
use array::SpanTrait;

// TODO use this once all stuff rewritten in components
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct GasFee {
    gas_per_action: u256,
    fee_token: ContractAddress,
    max_gas_price: u256,
    conversion_rate: (u256, u256),
    external_call: bool,
}




#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct FixedFee {
    recipient: ContractAddress,
    fee_token: ContractAddress,
    maker_pbips: u64,
    taker_pbips: u64,
    external_call: bool,
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
    price_address: ContractAddress,
    qty_address: ContractAddress,
    fee: OrderFee,
    number_of_swaps_allowed: u8,
    salt: felt252,
    nonce: u32,
    flags:OrderFlags
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SignedOrder {
    order: Order,
    sign: (felt252, felt252),
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct OrderTradeInfo {
    filled_amount: u256,
    last_traded_px: u256,
    num_trades_happened: u8,
    remaining_qty: u256,
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
            
            return orders_trade_info.remaining_qty;
        }
    return order.quantity;
    // FULL_FILL_ONLY_FLAG checked by user of this func and sign too
}
