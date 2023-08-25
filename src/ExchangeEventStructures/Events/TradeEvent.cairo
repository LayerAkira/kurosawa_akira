use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEventStructures::Events::FundsTraits::PoseidonHashImpl;
use kurosawa_akira::ExchangeEventStructures::Events::Order::Order;
use kurosawa_akira::ExchangeEventStructures::Events::Order::get_order_hash;
use kurosawa_akira::ExchangeEventStructures::Events::Order::validate_order;
use kurosawa_akira::ExchangeEventStructures::ExchangeEvent::Applying;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_filled_amount_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_filled_amount_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::apply_transaction_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_apply_transaction_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::mathing_amount_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_mathing_amount_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::matching_price_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_matching_price_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::price_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_price_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::order_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_order_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::user_balance_snapshot;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_user_balance_snapshot;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;
use starknet::Store;


fn min(a: u256, b: u256) -> u256 {
    if a > b {
        b
    } else {
        a
    }
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Trade {
    maker_order: Order,
    maker_order_signature: (felt252, felt252),
    taker_order: Order,
    taker_order_signature: (felt252, felt252),
}

impl ApplyingTradeImpl of Applying<Trade> {
    fn apply(self: Trade, ref state: ContractState) {
        let trade = self;
        emit_apply_transaction_started(ref state, apply_transaction_started {});
        emit_order_event(ref state, order_event { order: trade.maker_order });
        emit_order_event(ref state, order_event { order: trade.taker_order });
        let maker_order_hash = trade.maker_order.get_poseidon_hash();
        let taker_order_hash = trade.taker_order.get_poseidon_hash();
        let maker_amount = validate_order(trade.maker_order, maker_order_hash, trade.maker_order_signature, ref state);
        let taker_amount = validate_order(trade.taker_order, taker_order_hash, trade.taker_order_signature, ref state);
        let mathing_amount: u256 = min(taker_amount, maker_amount);
        emit_mathing_amount_event(ref state, mathing_amount_event { amount: mathing_amount });
        let matching_price: u256 = trade.maker_order.price;
        emit_matching_price_event(ref state, matching_price_event { amount: matching_price });
        _filled_amount_write(
            ref state,
            maker_order_hash,
            _filled_amount_read(ref state, maker_order_hash) + mathing_amount
        );
        _filled_amount_write(
            ref state,
            taker_order_hash,
            _filled_amount_read(ref state, taker_order_hash) + mathing_amount
        );
        rebalance_after_trade(
            trade.maker_order.side,
            trade,
            mathing_amount,
            mathing_amount * matching_price,
            ref state
        );
    }
}

fn rebalance_after_trade(
    is_maker_SELL_side: bool,
    trade: Trade,
    amount_maker: u256,
    amount_taker: u256,
    ref state: ContractState
) {
    if is_maker_SELL_side {
        _balance_write(
            ref state,
            (trade.maker_order.qty_address, trade.maker_order.maker),
            _balance_read(ref state, (trade.maker_order.qty_address, trade.maker_order.maker))
                - amount_maker
        );
        _balance_write(
            ref state,
            (trade.taker_order.qty_address, trade.taker_order.maker),
            _balance_read(ref state, (trade.taker_order.qty_address, trade.taker_order.maker))
                + amount_maker
        );
        _balance_write(
            ref state,
            (trade.maker_order.price_address, trade.maker_order.maker),
            _balance_read(ref state, (trade.maker_order.price_address, trade.maker_order.maker))
                + amount_taker
        );
        _balance_write(
            ref state,
            (trade.taker_order.price_address, trade.taker_order.maker),
            _balance_read(ref state, (trade.taker_order.price_address, trade.taker_order.maker))
                - amount_taker
        );
    } else {
        _balance_write(
            ref state,
            (trade.maker_order.qty_address, trade.maker_order.maker),
            _balance_read(ref state, (trade.maker_order.qty_address, trade.maker_order.maker))
                + amount_maker
        );
        _balance_write(
            ref state,
            (trade.taker_order.qty_address, trade.taker_order.maker),
            _balance_read(ref state, (trade.taker_order.qty_address, trade.taker_order.maker))
                - amount_maker
        );
        _balance_write(
            ref state,
            (trade.maker_order.price_address, trade.maker_order.maker),
            _balance_read(ref state, (trade.maker_order.price_address, trade.maker_order.maker))
                - amount_taker
        );
        _balance_write(
            ref state,
            (trade.taker_order.price_address, trade.taker_order.maker),
            _balance_read(ref state, (trade.taker_order.price_address, trade.taker_order.maker))
                + amount_taker
        );
    }
    emit_user_balance_snapshot(
        ref state,
        user_balance_snapshot {
            user_address: trade.maker_order.maker,
            token: trade.maker_order.qty_address,
            balance: _balance_read(
                ref state, (trade.maker_order.qty_address, trade.maker_order.maker)
            )
        }
    );
    emit_user_balance_snapshot(
        ref state,
        user_balance_snapshot {
            user_address: trade.maker_order.maker,
            token: trade.maker_order.price_address,
            balance: _balance_read(
                ref state, (trade.maker_order.price_address, trade.maker_order.maker)
            )
        }
    );
    emit_user_balance_snapshot(
        ref state,
        user_balance_snapshot {
            user_address: trade.taker_order.maker,
            token: trade.taker_order.qty_address,
            balance: _balance_read(
                ref state, (trade.taker_order.qty_address, trade.taker_order.maker)
            )
        }
    );
    emit_user_balance_snapshot(
        ref state,
        user_balance_snapshot {
            user_address: trade.taker_order.maker,
            token: trade.taker_order.price_address,
            balance: _balance_read(
                ref state, (trade.taker_order.price_address, trade.taker_order.maker)
            )
        }
    );
}

