use core::traits::Into;
use starknet::ContractAddress;
use serde::Serde;
use poseidon::poseidon_hash_span;
use array::ArrayTrait;
use array::SpanTrait;
use starknet::{get_block_timestamp};

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



// later trade group id can be binned together if multisig happens, offchain execution

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
enum TakerSelfTradePreventionMode {
    NONE, // allow self trading
    EXPIRE_TAKER, // on contract side wont allow orders to match if they have same order signer, on exchange expiring remaining qty of taker
    EXPIRE_MAKER, // on contract side wont allow orders to match if they have same order signer, on exchange expiring remaining qty of maker's orders
    EXPIRE_BOTH, // on contract side wont allow orders to match, on exchange expiring remaining qty of taker and makers orders
} // semantic take place only depending on takers' order mode


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Order {
    maker: ContractAddress, // trading account that created order
    price: u256, // price in quote asset raw amount, for taker order serves as protection price, for passive order executoin price
    quantity: u256, // quantity in base asset raw amount
    ticker: (ContractAddress, ContractAddress), // (base asset address, quote asset address) eg ETH/USDC
    fee: OrderFee, // order fees that user must fulfill once trade happens
    number_of_swaps_allowed: u8, // if order is taker, one can limit maximum number of trades can happens with this taker order (necesasry becase taker order incur gas fees)
    salt: felt252, // random salt for security
    nonce: u32, // maker nonce, for order be valid this nonce must be >= in Nonce component
    flags: OrderFlags, // various order flags of order
    router_signer: ContractAddress, // if taker order is unsafe aka trader outside of our ecosystem then this is router that router this trader to us, for makers and safe order always 0
    base_asset: u256, // raw amount of base asset representing 1, eg 1 eth is 10**18
    created_at: u32, // epoch time in seconds, time when order was created by user
    stp: TakerSelfTradePreventionMode,
    expire_at: u32, // epoch tine in seconds, time when order becomes invalid
    version: u16 // exchange version 
}   

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SignedOrder {
    order: Order,
    sign: (felt252, felt252), // makers' signer signature of poseidon hash of order,
    router_sign: (felt252,felt252) // router_signer signature of poseidon hash of order in case of unsafe taker order, else (0, 0)
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct OrderTradeInfo {
    filled_amount: u256,
    last_traded_px: u256,
    num_trades_happened: u8,
    as_taker_completed: bool
}


fn get_feeable_qty(fixed_fee: FixedFee, feeable_qty: u256, is_maker:bool) -> u256 {
    let pbips = if is_maker {fixed_fee.maker_pbips} else {fixed_fee.taker_pbips};
    if pbips == 0 { return 0;}
    return (feeable_qty * pbips.into() - 1) / 1_000_000 + 1;
}

fn get_limit_px(maker_order:Order, maker_fill_info:OrderTradeInfo) -> (u256, u256){
    let settle_px = if maker_fill_info.filled_amount > 0 {maker_fill_info.last_traded_px} else {maker_order.price};
    return (settle_px, maker_order.quantity - maker_fill_info.filled_amount); 
}

fn do_taker_price_checks(taker_order:Order, settle_px:u256, taker_fill_info:OrderTradeInfo)->u256 {
    assert!(taker_order.flags.is_sell_side || settle_px <= taker_order.price, "BUY_PROTECTION_PRICE_FAILED: settle_px ({}) <= taker_order.price ({})", settle_px, taker_order.price);
    assert!(!taker_order.flags.is_sell_side || settle_px >= taker_order.price, "SELL_PROTECTION_PRICE_FAILED: settle_px ({}) >= taker_order.price ({})", settle_px, taker_order.price); 

    if taker_fill_info.filled_amount > 0 {
        let last_traded_px = taker_fill_info.last_traded_px;
        if taker_order.flags.best_level_only { assert!(last_traded_px == settle_px , "BEST_LVL_ONLY: failed last_traded_px ({}) == settle_px ({})", last_traded_px, settle_px);}
        else {
            if !taker_order.flags.is_sell_side { assert!(last_traded_px <= settle_px, "BUY_PARTIAL_FILL_ERR: failed last_traded_px ({}) <= settle_px ({})", last_traded_px, settle_px);} 
            else { assert!(last_traded_px >= settle_px, "SELL_PARTIAL_FILL_ERR: failed last_traded_px ({}) >= settle_px ({})", last_traded_px, settle_px);}
        }
    }
    let rem = taker_order.quantity - taker_fill_info.filled_amount;
    assert!(rem > 0, "FILLED_TAKER_ORDER");
    return rem;
}

fn do_maker_checks(maker_order:Order, maker_fill_info:OrderTradeInfo, nonce:u32)-> (u256, u256) {
    assert!(!maker_order.flags.is_market_order, "WRONG_MARKET_TYPE");
    let remaining = maker_order.quantity - maker_fill_info.filled_amount;
    assert!(remaining > 0, "MAKER_ALREADY_FILLED: remaining = ({})", remaining);
    assert!(maker_order.nonce >= nonce, "OLD_MAKER_NONCE: failed maker_order.nonce ({}) >= nonce ({})", maker_order.nonce, nonce);
    assert!(!maker_order.flags.full_fill_only, "WRONG_MAKER_FLAG: maker_order can't be full_fill_only");
    assert!(get_block_timestamp() < maker_order.expire_at.into(), "Maker order expire {}", maker_order.expire_at);
    if maker_order.flags.post_only {
        assert!(!maker_order.flags.best_level_only && !maker_order.flags.full_fill_only, "WRONG_MAKER_FLAGS");
    }
    let settle_px = if maker_fill_info.filled_amount > 0 {maker_fill_info.last_traded_px} else {maker_order.price};


    return (settle_px, remaining); 
}


fn get_gas_fee_and_coin(gas_fee: GasFee, cur_gas_price: u256, native_token:ContractAddress) -> (u256, ContractAddress) {
    if cur_gas_price == 0 { return (0, native_token);}
    if gas_fee.gas_per_action == 0 { return (0, native_token);}
    assert!(gas_fee.max_gas_price >= cur_gas_price, "Failed: max_gas_price ({}) >= cur_gas_price ({})", gas_fee.max_gas_price, cur_gas_price);
    let spend_native = gas_fee.gas_per_action.into() * cur_gas_price;
    
    if gas_fee.fee_token == native_token {
        return (spend_native, native_token);
    }

    let (r0, r1) = gas_fee.conversion_rate;
    let spend_converted = spend_native * r1 / r0;
    return (spend_converted, gas_fee.fee_token);
}
