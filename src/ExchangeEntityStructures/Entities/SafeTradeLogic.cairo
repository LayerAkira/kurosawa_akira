use kurosawa_akira::ExchangeEntityStructures::Entities::TradeEntity::Trade;
#[starknet::interface]
trait ISafeTradeLogic<TContractState> {
    fn apply_trade_event(ref self: TContractState, trade: Trade);
}


#[starknet::contract]
mod SafeTradeLogicContract {
    use starknet::ContractAddress;
    use kurosawa_akira::ExchangeEntityStructures::Entities::CommonTradeLogic::ICommonTradeLogicContractDispatcher;
    use kurosawa_akira::ExchangeEntityStructures::Entities::CommonTradeLogic::ICommonTradeLogicContractDispatcherTrait;
    use kurosawa_akira::utils::common::min;
    use kurosawa_akira::ExchangeEntityStructures::Entities::CommonTradeLogic::OrderTradeInfo;
    use kurosawa_akira::ExchangeEntityStructures::Entities::Order::Order;
    use kurosawa_akira::ExchangeEntityStructures::Entities::Order::SignedOrder;
    use kurosawa_akira::ExchangeEntityStructures::Entities::TradeEntity::Trade;
    use kurosawa_akira::FeeLogic::FixedFee::FixedFee;
    use kurosawa_akira::FeeLogic::OrderFee::OrderFee;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHashImpl;


    #[storage]
    struct Storage {
        exchange_balance_contract: ContractAddress,
        common_trade_logic_contract: ContractAddress,
        last_taker_order_and_require_fill: LegacyMap::<
            (ContractAddress, ContractAddress, bool), (felt252, bool)
        >,
        pow_of_decimals: LegacyMap::<ContractAddress, u256>,
    }


    #[constructor]
    fn constructor(
        ref self: ContractState,
        exchange_balance_contract: ContractAddress,
        common_trade_logic_contract: ContractAddress,
        ETH: ContractAddress,
        BTC: ContractAddress,
        USDC: ContractAddress,
    ) {
        self.exchange_balance_contract.write(exchange_balance_contract);
        self.common_trade_logic_contract.write(common_trade_logic_contract);
        self.pow_of_decimals.write(ETH, 1000000000000000000);
        self.pow_of_decimals.write(BTC, 100000000);
        self.pow_of_decimals.write(USDC, 1000000);
    }

    fn validate_taker_order(
        ref self: ContractState,
        signed_order: SignedOrder,
        order_hash: felt252,
        settlement_price: u256
    ) -> u256 {
        let common_trade_logic_contract_dispatcher = ICommonTradeLogicContractDispatcher {
            contract_address: self.common_trade_logic_contract.read()
        };
        let order = signed_order.order;
        let remaining_qty = common_trade_logic_contract_dispatcher
            .validate_taker_order(signed_order, order_hash, settlement_price);
        if order.quantity != remaining_qty {
            let (prev_taker_order, _) = self
                .last_taker_order_and_require_fill
                .read((order.qty_address, order.price_address, order.side));
            assert(prev_taker_order == order_hash, 'if part exec=>prev taker_o=same');
        }
        return remaining_qty;
    }


    #[external(v0)]
    fn apply_trade_event(ref self: ContractState, trade: Trade) {
        let maker_o = trade.maker_signed_order.order;
        let taker_o = trade.taker_signed_order.order;

        assert(
            taker_o.qty_address == maker_o.qty_address
                && taker_o.price_address == maker_o.price_address,
            'Mismatch tickers'
        );
        assert(taker_o.to_safe_book == maker_o.to_safe_book, 'Wrong book destination');
        let maker_hash = maker_o.get_poseidon_hash();
        let taker_hash = taker_o.get_poseidon_hash();

        let common_trade_logic_contract_dispatcher = ICommonTradeLogicContractDispatcher {
            contract_address: self.common_trade_logic_contract.read()
        };

        let tradable_maker_qty = common_trade_logic_contract_dispatcher
            .validate_maker_order(trade.maker_signed_order, maker_hash);
        let tradable_taker_wty = validate_taker_order(
            ref self, trade.taker_signed_order, taker_hash, maker_o.price
        );
        let match_qty = min(tradable_maker_qty, tradable_taker_wty);
        let match_px = maker_o.price;

        let qty_decimals: u256 = self.pow_of_decimals.read(maker_o.qty_address);
        let matching_cost = match_px * match_qty / qty_decimals;

        assert(matching_cost > 0, '0 matching cost');

        self
            .emit(
                Event::trade_event(
                    trade_event_s {
                        maker_hash: maker_hash,
                        taker_hash: taker_hash,
                        price: maker_o.price,
                        qty: match_qty,
                        maker: maker_o.maker,
                        taker: taker_o.maker,
                        side: taker_o.side,
                    }
                )
            );

        common_trade_logic_contract_dispatcher
            .rebalance_after_trade(maker_o.side == false, trade, match_qty, matching_cost);
        if maker_o.side == false {
            common_trade_logic_contract_dispatcher
                .apply_order_fee_safe(
                    maker_o.maker, maker_o.fee, matching_cost, maker_o.qty_address, true
                );
            common_trade_logic_contract_dispatcher
                .apply_order_fee_safe(
                    taker_o.maker, taker_o.fee, match_qty, taker_o.price_address, false
                );
        } else {
            common_trade_logic_contract_dispatcher
                .apply_order_fee_safe(
                    maker_o.maker, maker_o.fee, match_qty, maker_o.price_address, true
                );
            common_trade_logic_contract_dispatcher
                .apply_order_fee_safe(
                    taker_o.maker, taker_o.fee, matching_cost, taker_o.qty_address, false
                );
        }

        let (hash, fill_rq) = self
            .last_taker_order_and_require_fill
            .read((taker_o.qty_address, taker_o.price_address, taker_o.side));
        let t = common_trade_logic_contract_dispatcher.orders_trade_info_read(taker_hash);
        let m = common_trade_logic_contract_dispatcher.orders_trade_info_read(maker_hash);
        if hash != taker_hash {
            assert(!fill_rq || t.remaining_qty == 0, 'previous fok order not filled');
            self
                .last_taker_order_and_require_fill
                .write(
                    (taker_o.qty_address, taker_o.price_address, taker_o.side),
                    (taker_hash, taker_o.full_fill_only)
                )
        }

        common_trade_logic_contract_dispatcher
            .orders_trade_info_write(
                maker_hash,
                OrderTradeInfo {
                    filled_amount: m.filled_amount + match_qty,
                    last_traded_px: match_px,
                    num_trades_happened: m.num_trades_happened + 1,
                    remaining_qty: maker_o.quantity - m.filled_amount - match_qty
                }
            );
        common_trade_logic_contract_dispatcher
            .orders_trade_info_write(
                taker_hash,
                OrderTradeInfo {
                    filled_amount: t.filled_amount + match_qty,
                    last_traded_px: match_px,
                    num_trades_happened: t.num_trades_happened + 1,
                    remaining_qty: taker_o.quantity - t.filled_amount - match_qty
                }
            );
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        trade_event: trade_event_s,
    }

    #[derive(Drop, starknet::Event)]
    struct trade_event_s {
        maker_hash: felt252,
        taker_hash: felt252,
        price: u256,
        qty: u256,
        maker: ContractAddress,
        taker: ContractAddress,
        side: bool,
    }
}
