use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEventStructures::Events::FundsTraits::PoseidonHashImpl;
use kurosawa_akira::ExchangeEventStructures::Events::Order::Order;
use kurosawa_akira::ExchangeEventStructures::Events::Order::SignedOrder;
use kurosawa_akira::ExchangeEventStructures::Events::Order::validate_order;
use kurosawa_akira::ExchangeEventStructures::ExchangeEvent::Applying;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_filled_amount_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_filled_amount_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_pow_of_decimals_read;
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
    maker_signed_order: SignedOrder,
    taker_signed_order: SignedOrder,
}

impl ApplyingTradeImpl of Applying<Trade> {
    fn apply(self: Trade, ref state: ContractState) {
        let trade = self;
        emit_apply_transaction_started(ref state, apply_transaction_started {});
        emit_order_event(ref state, order_event { order: trade.maker_signed_order.order });
        emit_order_event(ref state, order_event { order: trade.taker_signed_order.order });
        let maker_order_hash = trade.maker_signed_order.order.get_poseidon_hash();
        let taker_order_hash = trade.taker_signed_order.order.get_poseidon_hash();
        let maker_amount = validate_order(trade.maker_signed_order, maker_order_hash, ref state);
        let taker_amount = validate_order(trade.taker_signed_order, taker_order_hash, ref state);
        let mathing_amount: u256 = min(taker_amount, maker_amount);
        emit_mathing_amount_event(ref state, mathing_amount_event { amount: mathing_amount });
        let matching_price: u256 = trade.maker_signed_order.order.price;
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

        let qty_decimals: u256 = _pow_of_decimals_read(ref state, trade.maker_signed_order.order.qty_address);

        let mathing_cost: u256 = (matching_price * mathing_amount) / qty_decimals;

        rebalance_after_trade(
            trade.maker_signed_order.order.side,
            trade,
            mathing_amount,
            mathing_cost,
            ref state
        );
        if trade.maker_signed_order.order.side == true {
            apply_order_fee(ref state, trade.maker_signed_order.order.maker, trade.maker_signed_order.order.fee,
                mathing_cost, trade.maker_signed_order.order.price_address, true);
            apply_order_fee(ref state, trade.taker_signed_order.order.maker, trade.taker_signed_order.order.fee,
                mathing_amount, trade.taker_signed_order.order.qty_address, false);
        }
        else {
            apply_order_fee(ref state, trade.maker_signed_order.order.maker, trade.maker_signed_order.order.fee,
                mathing_amount, trade.maker_signed_order.order.qty_address, true);
            apply_order_fee(ref state, trade.taker_signed_order.order.maker, trade.taker_signed_order.order.fee,
                mathing_cost, trade.taker_signed_order.order.price_address, false);
        }
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
            (trade.maker_signed_order.order.qty_address, trade.maker_signed_order.order.maker),
            _balance_read(ref state, (trade.maker_signed_order.order.qty_address, trade.maker_signed_order.order.maker))
                - amount_maker
        );
        _balance_write(
            ref state,
            (trade.taker_signed_order.order.qty_address, trade.taker_signed_order.order.maker),
            _balance_read(ref state, (trade.taker_signed_order.order.qty_address, trade.taker_signed_order.order.maker))
                + amount_maker
        );
        _balance_write(
            ref state,
            (trade.maker_signed_order.order.price_address, trade.maker_signed_order.order.maker),
            _balance_read(ref state, (trade.maker_signed_order.order.price_address, trade.maker_signed_order.order.maker))
                + amount_taker
        );
        _balance_write(
            ref state,
            (trade.taker_signed_order.order.price_address, trade.taker_signed_order.order.maker),
            _balance_read(ref state, (trade.taker_signed_order.order.price_address, trade.taker_signed_order.order.maker))
                - amount_taker
        );
    } else {
        _balance_write(
            ref state,
            (trade.maker_signed_order.order.qty_address, trade.maker_signed_order.order.maker),
            _balance_read(ref state, (trade.maker_signed_order.order.qty_address, trade.maker_signed_order.order.maker))
                + amount_maker
        );
        _balance_write(
            ref state,
            (trade.taker_signed_order.order.qty_address, trade.taker_signed_order.order.maker),
            _balance_read(ref state, (trade.taker_signed_order.order.qty_address, trade.taker_signed_order.order.maker))
                - amount_maker
        );
        _balance_write(
            ref state,
            (trade.maker_signed_order.order.price_address, trade.maker_signed_order.order.maker),
            _balance_read(ref state, (trade.maker_signed_order.order.price_address, trade.maker_signed_order.order.maker))
                - amount_taker
        );
        _balance_write(
            ref state,
            (trade.taker_signed_order.order.price_address, trade.taker_signed_order.order.maker),
            _balance_read(ref state, (trade.taker_signed_order.order.price_address, trade.taker_signed_order.order.maker))
                + amount_taker
        );
    }
    emit_user_balance_snapshot(
        ref state,
        user_balance_snapshot {
            user_address: trade.maker_signed_order.order.maker,
            token: trade.maker_signed_order.order.qty_address,
            balance: _balance_read(
                ref state, (trade.maker_signed_order.order.qty_address, trade.maker_signed_order.order.maker)
            )
        }
    );
    emit_user_balance_snapshot(
        ref state,
        user_balance_snapshot {
            user_address: trade.maker_signed_order.order.maker,
            token: trade.maker_signed_order.order.price_address,
            balance: _balance_read(
                ref state, (trade.maker_signed_order.order.price_address, trade.maker_signed_order.order.maker)
            )
        }
    );
    emit_user_balance_snapshot(
        ref state,
        user_balance_snapshot {
            user_address: trade.taker_signed_order.order.maker,
            token: trade.taker_signed_order.order.qty_address,
            balance: _balance_read(
                ref state, (trade.taker_signed_order.order.qty_address, trade.taker_signed_order.order.maker)
            )
        }
    );
    emit_user_balance_snapshot(
        ref state,
        user_balance_snapshot {
            user_address: trade.taker_signed_order.order.maker,
            token: trade.taker_signed_order.order.price_address,
            balance: _balance_read(
                ref state, (trade.taker_signed_order.order.price_address, trade.taker_signed_order.order.maker)
            )
        }
    );
}

