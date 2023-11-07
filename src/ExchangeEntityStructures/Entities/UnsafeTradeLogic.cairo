#[starknet::contract]
mod UnsafeTradeLogicContract {
    use starknet::ContractAddress;
    use kurosawa_akira::RouterLogic::IRouterLogicContractDispatcher;
    use kurosawa_akira::RouterLogic::IRouterLogicContractDispatcherTrait;
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
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcher;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20Dispatcher;


    #[storage]
    struct Storage {
        exchange_balance_contract: ContractAddress,
        exchange_routers_balance_contract: ContractAddress,
        nonces_contract: ContractAddress,
        common_trade_logic_contract: ContractAddress,
        router_logic_contract: ContractAddress,
        exchange_address: ContractAddress,
        wrapped_base_token: ContractAddress,
        pow_of_decimals: LegacyMap::<ContractAddress, u256>,
    }


    #[constructor]
    fn constructor(
        ref self: ContractState,
        exchange_balance_contract: ContractAddress,
        exchange_routers_balance_contract: ContractAddress,
        nonces_contract: ContractAddress,
        common_trade_logic_contract: ContractAddress,
        router_logic_contract: ContractAddress,
        exchange_address: ContractAddress,
        wrapped_base_token: ContractAddress,
        ETH: ContractAddress,
        BTC: ContractAddress,
        USDC: ContractAddress,
    ) {
        self.exchange_balance_contract.write(exchange_balance_contract);
        self.exchange_routers_balance_contract.write(exchange_routers_balance_contract);
        self.nonces_contract.write(nonces_contract);
        self.common_trade_logic_contract.write(common_trade_logic_contract);
        self.router_logic_contract.write(router_logic_contract);
        self.exchange_address.write(exchange_address);
        self.wrapped_base_token.write(wrapped_base_token);
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
        let order = signed_order.order;
        let common_trade_logic_contract_dispatcher = ICommonTradeLogicContractDispatcher {
            contract_address: self.common_trade_logic_contract.read()
        };
        let router_logic_contract_dispatcher = IRouterLogicContractDispatcher {
            contract_address: self.router_logic_contract.read()
        };
        let remaining_qty = common_trade_logic_contract_dispatcher
            .validate_taker_order(signed_order, order_hash, settlement_price);
        assert(order.to_safe_book == false, 'unsafe book should be');
        router_logic_contract_dispatcher
            .validate_router(order_hash, signed_order.sign, order.fee.router_fee.recipient);
        return remaining_qty;
    }

    fn validate_maker_order(ref self: ContractState, signed_order: SignedOrder,) -> u256 {
        let common_trade_logic_contract_dispatcher = ICommonTradeLogicContractDispatcher {
            contract_address: self.common_trade_logic_contract.read()
        };
        let order = signed_order.order;
        let order_hash = order.get_poseidon_hash();
        let remaining_qty = common_trade_logic_contract_dispatcher
            .validate_maker_order(signed_order, order_hash);
        assert(order.to_safe_book == false, 'unsafe book should be');
        assert(order.post_only == false, 'only po maker order to unsafe');
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
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        if !validate_uncertanty_and_prepare_and_pay_upfront_gas(
            ref self,
            taker_o,
            maker_o,
            maker_o.side == false,
            match_qty,
            matching_cost,
            exchange_balance_dispatcher.get_cur_gas_price(),
        ) {
            return;
        }

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

            apply_taker_fee_fixed_and_tfer(
                ref self, taker_o.maker, taker_o.fee, match_qty, maker_o.qty_address
            );
        } else {
            common_trade_logic_contract_dispatcher
                .apply_order_fee_safe(
                    maker_o.maker, maker_o.fee, match_qty, maker_o.price_address, true
                );

            apply_taker_fee_fixed_and_tfer(
                ref self, taker_o.maker, taker_o.fee, matching_cost, maker_o.qty_address
            );
        }

        let t = common_trade_logic_contract_dispatcher.orders_trade_info_read(taker_hash);
        let m = common_trade_logic_contract_dispatcher.orders_trade_info_read(maker_hash);

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

    fn validate_able_move_external(
        ref self: ContractState,
        taker_o: Order,
        erc_token: ContractAddress,
        qty: u256,
        recipient: ContractAddress
    ) -> u256 {
        let erc = IERC20Dispatcher { contract_address: erc_token };
        let have_qty = erc.balanceOf(taker_o.maker) >= qty;
        let allowed = erc.allowance(taker_o.maker, recipient) >= qty;
        if have_qty == false || allowed == false {
            return 0;
        }
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        let prev = exchange_balance_dispatcher.balanceOf(recipient, taker_o.price_address);
        erc.transferFrom(taker_o.maker, recipient, qty);
        let received = erc.balanceOf(recipient) - prev;
        return received;
    }

    fn validate_uncertanty_and_prepare_and_pay_upfront_gas(
        ref self: ContractState,
        taker_o: Order,
        maker_o: Order,
        is_maker_buy: bool,
        match_qty: u256,
        matching_cost: u256,
        cur_gas_price: u256,
    ) -> bool {
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };

        let (gas_spend, gas_token) = exchange_balance_dispatcher
            .get_gas_fee_and_coin(taker_o.fee.gas_fee, cur_gas_price);
        let gas_received = validate_able_move_external(
            ref self, taker_o, gas_token, gas_spend, self.exchange_address.read()
        );
        if gas_received > 0 {
            self
                .emit(
                    Event::fee_event(
                        fee_event_s {
                            sender: taker_o.maker,
                            recipient: self.exchange_address.read(),
                            token: gas_token,
                            amount: gas_received,
                        }
                    )
                );
            exchange_balance_dispatcher.mint(self.exchange_address.read(), gas_received, gas_token);
        }

        if gas_received != gas_spend {
            handle_failed_trade(ref self, taker_o, maker_o.maker);
            return false;
        }
        if is_maker_buy {
            let received_qty = validate_able_move_external(
                ref self, taker_o, taker_o.price_address, match_qty, self.exchange_address.read()
            );
            if received_qty != match_qty {
                self
                    .emit(
                        Event::mismatch_fee(
                            mismatch_fee_s {
                                sender: taker_o.maker,
                                recipient: self.exchange_address.read(),
                                token: taker_o.price_address,
                                amount: received_qty,
                            }
                        )
                    );

                exchange_balance_dispatcher
                    .mint(taker_o.fee.trade_fee.recipient, received_qty, taker_o.price_address);
                handle_failed_trade(ref self, taker_o, maker_o.maker);
                return false;
            }
            exchange_balance_dispatcher.mint(taker_o.maker, received_qty, taker_o.price_address);
        } else {
            let received_qty = validate_able_move_external(
                ref self, taker_o, taker_o.qty_address, matching_cost, self.exchange_address.read()
            );
            if received_qty != matching_cost {
                self
                    .emit(
                        Event::mismatch_fee(
                            mismatch_fee_s {
                                sender: taker_o.maker,
                                recipient: self.exchange_address.read(),
                                token: taker_o.qty_address,
                                amount: received_qty,
                            }
                        )
                    );

                exchange_balance_dispatcher
                    .mint(taker_o.fee.trade_fee.recipient, received_qty, taker_o.qty_address);
                handle_failed_trade(ref self, taker_o, maker_o.maker);
                return false;
            }
            exchange_balance_dispatcher.mint(taker_o.maker, received_qty, taker_o.qty_address);
        }
        return true;
    }

    fn handle_failed_trade(
        ref self: ContractState, taker_order: Order, victim_user: ContractAddress
    ) {
        let router_logic_contract_dispatcher = IRouterLogicContractDispatcher {
            contract_address: self.router_logic_contract.read()
        };
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        let spend_native = taker_order.fee.gas_fee.gas_per_swap
            * exchange_balance_dispatcher.get_cur_gas_price();
        let bad_router = taker_order.fee.router_fee.recipient;
        let punish_factor = router_logic_contract_dispatcher.get_punishment_factor_bips();
        let punish_value = punish_factor * spend_native / 10000;

        let exchange_routers_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_routers_balance_contract.read()
        };

        exchange_routers_balance_dispatcher
            .burn(bad_router, punish_value, self.wrapped_base_token.read());

        exchange_balance_dispatcher.mint(victim_user, punish_value, self.wrapped_base_token.read());
        exchange_balance_dispatcher
            .mint(self.exchange_address.read(), punish_value, self.wrapped_base_token.read());

        self
            .emit(
                Event::punish_event(
                    punish_event_s {
                        router: bad_router, recipient: victim_user, amount: punish_value,
                    }
                )
            );
        self
            .emit(
                Event::punish_event(
                    punish_event_s {
                        router: bad_router,
                        recipient: self.exchange_address.read(),
                        amount: punish_value,
                    }
                )
            );
    }

    fn apply_taker_fee_fixed_and_tfer(
        ref self: ContractState,
        user: ContractAddress,
        fee: OrderFee,
        feeable_qty: u256,
        fee_token: ContractAddress,
    ) {
        assert(fee.trade_fee.fee_token == fee_token, 'wrong fee token, require same');
        assert(fee.router_fee.fee_token == fee_token, 'wrong fee token, require same');

        let common_trade_logic_contract_dispatcher = ICommonTradeLogicContractDispatcher {
            contract_address: self.common_trade_logic_contract.read()
        };
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        let exchange_routers_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_routers_balance_contract.read()
        };

        let trade_fee = common_trade_logic_contract_dispatcher
            .get_feeable_qty(fee.trade_fee, feeable_qty);
        if trade_fee > 0 {
            exchange_balance_dispatcher
                .internal_transfer(user, fee.trade_fee.recipient, trade_fee, fee_token);

            self
                .emit(
                    Event::fee_event(
                        fee_event_s {
                            sender: user,
                            recipient: fee.trade_fee.recipient,
                            token: fee_token,
                            amount: trade_fee,
                        }
                    )
                );
        }

        let router_fee = common_trade_logic_contract_dispatcher
            .get_feeable_qty(fee.router_fee, feeable_qty);
        if router_fee > 0 {
            exchange_balance_dispatcher.burn(user, router_fee, fee_token);
            exchange_routers_balance_dispatcher
                .mint(fee.router_fee.recipient, router_fee, fee_token);

            self
                .emit(
                    Event::fee_event(
                        fee_event_s {
                            sender: user,
                            recipient: fee.router_fee.recipient,
                            token: fee_token,
                            amount: router_fee,
                        }
                    )
                );
        }

        let final = feeable_qty - trade_fee - router_fee;
        exchange_balance_dispatcher.burn(user, final, fee_token);
        IERC20Dispatcher { contract_address: fee_token }.transfer(user, final);
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        trade_event: trade_event_s,
        fee_event: fee_event_s,
        punish_event: punish_event_s,
        mismatch_fee: mismatch_fee_s,
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

    #[derive(Drop, starknet::Event)]
    struct fee_event_s {
        sender: ContractAddress,
        recipient: ContractAddress,
        token: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct punish_event_s {
        router: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct mismatch_fee_s {
        sender: ContractAddress,
        recipient: ContractAddress,
        token: ContractAddress,
        amount: u256,
    }
}
