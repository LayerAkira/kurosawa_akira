#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct OrderTradeInfo {
    filled_amount: u256,
    last_traded_px: u256,
    num_trades_happened: u256,
    remaining_qty: u256,
}
use starknet::ContractAddress;
use kurosawa_akira::ExchangeEntityStructures::Entities::Order::Order;
use kurosawa_akira::ExchangeEntityStructures::Entities::Order::SignedOrder;
use kurosawa_akira::ExchangeEntityStructures::Entities::TradeEntity::Trade;
use kurosawa_akira::FeeLogic::FixedFee::FixedFee;
use kurosawa_akira::FeeLogic::OrderFee::OrderFee;
#[starknet::interface]
trait ICommonTradeLogicContract<TContractState> {
    fn validate_maker_order(
        ref self: TContractState, signed_order: SignedOrder, order_hash: felt252
    ) -> u256;
    fn rebalance_after_trade(
        ref self: TContractState,
        is_maker_SELL_side: bool,
        trade: Trade,
        amount_maker: u256,
        amount_taker: u256
    );
    fn validate_taker_order(
        ref self: TContractState,
        signed_order: SignedOrder,
        order_hash: felt252,
        settlement_price: u256
    ) -> u256;
    fn apply_order_fee_safe(
        ref self: TContractState,
        user: ContractAddress,
        order_fee: OrderFee,
        feeable_qty: u256,
        fee_token: ContractAddress,
        is_maker: bool,
    );
    fn orders_trade_info_read(self: @TContractState, order_hash: felt252) -> OrderTradeInfo;
    fn orders_trade_info_write(
        ref self: TContractState, order_hash: felt252, order_trade_info: OrderTradeInfo
    );
    fn get_feeable_qty(self: @TContractState, fixed_fee: FixedFee, feeable_qty: u256) -> u256;
}

#[starknet::contract]
mod CommonTradeLogicContract {
    use starknet::ContractAddress;
    use super::OrderTradeInfo;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::check_sign;
    use kurosawa_akira::ExchangeEntityStructures::Entities::Order::Order;
    use kurosawa_akira::ExchangeEntityStructures::Entities::Order::SignedOrder;
    use kurosawa_akira::ExchangeEntityStructures::Entities::TradeEntity::Trade;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcher;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcherTrait;
    use kurosawa_akira::FeeLogic::FixedFee::FixedFee;
    use kurosawa_akira::FeeLogic::OrderFee::OrderFee;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;

    #[storage]
    struct Storage {
        exchange_balance_contract: ContractAddress,
        nonces: LegacyMap::<ContractAddress, u256>,
        orders_trade_info: LegacyMap::<felt252, OrderTradeInfo>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, exchange_balance_contract: ContractAddress) {
        self.exchange_balance_contract.write(exchange_balance_contract);
    }

    #[external(v0)]
    fn validate_maker_order(
        ref self: ContractState, signed_order: SignedOrder, order_hash: felt252
    ) -> u256 {
        let order = signed_order.order;
        check_sign(order.maker, order_hash, signed_order.sign);
        let orders_trade_info = self.orders_trade_info.read(order_hash);
        assert(order.order_type != true, 'Market order cant be maker');
        assert(order.quantity > orders_trade_info.filled_amount, 'fill amount fail');
        assert(order.nonce >= self.nonces.read(order.maker), 'old nonce');
        if order.post_only {
            assert(
                order.best_level_only == false && order.full_fill_only == false,
                'Wrong maker order type'
            );
            return order.quantity - orders_trade_info.filled_amount;
        }
        assert(order.full_fill_only == false, 'Wrong full fill only parameter');

        if orders_trade_info.filled_amount > 0 {
            assert(orders_trade_info.last_traded_px == order.price, 'partial => px shld be same');
        }
        return orders_trade_info.remaining_qty;
    }

    #[external(v0)]
    fn rebalance_after_trade(
        ref self: ContractState,
        is_maker_SELL_side: bool,
        trade: Trade,
        amount_maker: u256,
        amount_taker: u256
    ) {
        let base = trade.taker_signed_order.order.qty_address;
        let quote = trade.taker_signed_order.order.price_address;
        let maker_order = trade.maker_signed_order.order;
        let taker_order = trade.taker_signed_order.order;
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        if is_maker_SELL_side {
            assert(
                exchange_balance_dispatcher.balanceOf(quote, maker_order.maker) >= amount_maker,
                'insuff balance'
            );
            assert(
                exchange_balance_dispatcher.balanceOf(base, taker_order.maker) >= amount_taker,
                'insuff balance'
            );
            exchange_balance_dispatcher
                .internal_transfer(maker_order.maker, taker_order.maker, amount_maker, quote);
            exchange_balance_dispatcher
                .internal_transfer(taker_order.maker, maker_order.maker, amount_taker, base);
        } else {
            assert(
                exchange_balance_dispatcher.balanceOf(quote, taker_order.maker) >= amount_maker,
                'insuff balance'
            );
            assert(
                exchange_balance_dispatcher.balanceOf(base, maker_order.maker) >= amount_taker,
                'insuff balance'
            );
            exchange_balance_dispatcher
                .internal_transfer(taker_order.maker, maker_order.maker, amount_maker, quote);
            exchange_balance_dispatcher
                .internal_transfer(maker_order.maker, taker_order.maker, amount_taker, base);
        }
    }

    #[external(v0)]
    fn validate_taker_order(
        ref self: ContractState,
        signed_order: SignedOrder,
        order_hash: felt252,
        settlement_price: u256
    ) -> u256 {
        let order = signed_order.order;
        check_sign(order.maker, order_hash, signed_order.sign);
        let orders_trade_info = self.orders_trade_info.read(order_hash);
        assert(
            order.number_of_swaps_allowed > orders_trade_info.num_trades_happened, 'Too many trades'
        );
        assert(order.post_only == false, 'wrong post only flag for taker');
        assert(order.quantity > orders_trade_info.filled_amount, 'fill amount fail');
        assert(order.nonce >= self.nonces.read(order.maker), 'old nonce');
        if order.side == false {
            assert(order.price <= settlement_price, 'buy protection price failed');
        } else {
            assert(order.price >= settlement_price, 'sell protection price failed');
        }
        if orders_trade_info.filled_amount > 0 {
            if order.side == false {
                assert(
                    orders_trade_info.last_traded_px <= settlement_price,
                    'If partial, px cant be better'
                );
            } else {
                assert(
                    orders_trade_info.last_traded_px >= settlement_price,
                    'If partial, px cant be better'
                );
            }
            if order.best_level_only {
                assert(
                    orders_trade_info.last_traded_px == settlement_price,
                    'If partial, px should be same'
                );
            }
            return orders_trade_info.remaining_qty;
        }
        return order.quantity;
    }
    #[external(v0)]
    fn get_feeable_qty(self: @ContractState, fixed_fee: FixedFee, feeable_qty: u256) -> u256 {
        if fixed_fee.pbips == 0 {
            return 0;
        }
        return (feeable_qty * fixed_fee.pbips - 1) / 1000000 + 1;
    }


    fn apply_fixed_fee_involved(
        ref self: ContractState, user: ContractAddress, fixed_fee: FixedFee, feeable_qty: u256,
    ) {
        let fee = get_feeable_qty(@self, fixed_fee, feeable_qty);
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        if fee > 0 {
            exchange_balance_dispatcher
                .internal_transfer(user, fixed_fee.recipient, fee, fixed_fee.fee_token);
        }
        self
            .emit(
                Event::fee_event(
                    fee_event_s {
                        user: user,
                        recipient: fixed_fee.recipient,
                        fee_token: fixed_fee.fee_token,
                        fee: fee
                    }
                )
            );
    }
    #[external(v0)]
    fn apply_order_fee_safe(
        ref self: ContractState,
        user: ContractAddress,
        order_fee: OrderFee,
        feeable_qty: u256,
        fee_token: ContractAddress,
        is_maker: bool,
    ) {
        assert(order_fee.trade_fee.fee_token == fee_token, 'wrong fee token, require same');
        assert(order_fee.router_fee.is_zero() == false, 'safe requires no router fee');
        assert(order_fee.trade_fee.external_call == true, 'no external call allowed');
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        if !is_maker && !order_fee.gas_fee.is_zero() {
            exchange_balance_dispatcher.validate_and_apply_gas_fee_internal(user, order_fee.gas_fee)
        }
        apply_fixed_fee_involved(ref self, user, order_fee.trade_fee, feeable_qty);
    }

    #[external(v0)]
    fn orders_trade_info_read(self: @ContractState, order_hash: felt252) -> OrderTradeInfo {
        self.orders_trade_info.read(order_hash)
    }

    #[external(v0)]
    fn orders_trade_info_write(
        ref self: ContractState, order_hash: felt252, order_trade_info: OrderTradeInfo
    ) {
        self.orders_trade_info.write(order_hash, order_trade_info);
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        fee_event: fee_event_s
    }

    #[derive(Drop, starknet::Event)]
    struct fee_event_s {
        user: ContractAddress,
        recipient: ContractAddress,
        fee_token: ContractAddress,
        fee: u256,
    }
}
