use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEventStructures::Events::Order::Order;
use kurosawa_akira::ExchangeEventStructures::Events::Order::get_order_hash;
use kurosawa_akira::ExchangeEventStructures::Events::Order::validate_order;
use kurosawa_akira::ExchangeEventStructures::ExchangeEvent::Applying;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_filled_amount_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_filled_amount_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::apply_transaction_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::mathing_amount_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::matching_price_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::price_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::order_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::user_balance_snapshot;



fn min(a: u256, b: u256) -> u256 {
    if a > b {
        b
    } else {
        a
    }
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Trade {
    maker_order: Order,
    maker_order_signature: u256,
    taker_order: Order,
    taker_order_signature: u256,
}

impl ApplyingTradeImpl of Applying<Trade> {
    fn apply(self: Trade) {
        let trade = self;
        apply_transaction_started();
        order_event(trade.maker_order);
        order_event(trade.taker_order);
        let maker_order_hash = get_order_hash(trade.maker_order);
        let taker_order_hash = get_order_hash(trade.taker_order);
        let maker_amount = validate_order(trade.maker_order, maker_order_hash);
        let taker_amount = validate_order(trade.taker_order, taker_order_hash);
        let mathing_amount: u256 = min(taker_amount, maker_amount);
        mathing_amount_event(mathing_amount);
        let matching_price: u256 = trade.maker_order.price;
        matching_price_event(matching_price);
        _filled_amount_write(maker_order_hash, _filled_amount_read(maker_order_hash) + mathing_amount);
        _filled_amount_write(taker_order_hash, _filled_amount_read(taker_order_hash) + mathing_amount);
        rebalance_after_trade(
            trade.maker_order.side, trade, mathing_amount, mathing_amount * matching_price
        );
    }
}

fn rebalance_after_trade(
    is_maker_SELL_side: bool, trade: Trade, amount_maker: u256, amount_taker: u256
) {
    if is_maker_SELL_side {
        _balance_write(
            (trade.maker_order.qty_address, trade.maker_order.maker),
            _balance_read((trade.maker_order.qty_address, trade.maker_order.maker)) - amount_maker
        );
        _balance_write(
            (trade.taker_order.qty_address, trade.taker_order.maker),
            _balance_read((trade.taker_order.qty_address, trade.taker_order.maker)) + amount_maker
        );
        _balance_write(
            (trade.maker_order.price_address, trade.maker_order.maker),
            _balance_read((trade.maker_order.price_address, trade.maker_order.maker)) + amount_taker
        );
        _balance_write(
            (trade.taker_order.price_address, trade.taker_order.maker),
            _balance_read((trade.taker_order.price_address, trade.taker_order.maker)) - amount_taker
        );
    } else {
        _balance_write(
            (trade.maker_order.qty_address, trade.maker_order.maker),
            _balance_read((trade.maker_order.qty_address, trade.maker_order.maker)) + amount_maker
        );
        _balance_write(
            (trade.taker_order.qty_address, trade.taker_order.maker),
            _balance_read((trade.taker_order.qty_address, trade.taker_order.maker)) - amount_maker
        );
        _balance_write(
            (trade.maker_order.price_address, trade.maker_order.maker),
            _balance_read((trade.maker_order.price_address, trade.maker_order.maker)) - amount_taker
        );
        _balance_write(
            (trade.taker_order.price_address, trade.taker_order.maker),
            _balance_read((trade.taker_order.price_address, trade.taker_order.maker)) + amount_taker
        );
    }
    user_balance_snapshot(
        trade.maker_order.maker,
        trade.maker_order.qty_address,
        _balance_read((trade.maker_order.qty_address, trade.maker_order.maker))
    );
    user_balance_snapshot(
        trade.maker_order.maker,
        trade.maker_order.price_address,
        _balance_read((trade.maker_order.price_address, trade.maker_order.maker))
    );

    user_balance_snapshot(
        trade.taker_order.maker,
        trade.taker_order.qty_address,
        _balance_read((trade.taker_order.qty_address, trade.taker_order.maker))
    );
    user_balance_snapshot(
        trade.taker_order.maker,
        trade.taker_order.price_address,
        _balance_read((trade.taker_order.price_address, trade.taker_order.maker))
    );
}

