use kurosawa_akira::Order::{SignedOrder,Order, OrderTradeInfo,OrderFee,FixedFee,
            get_feeable_qty, get_limit_px, do_taker_price_checks, do_maker_checks,get_gas_fee_and_coin, GasFee};

#[starknet::interface]
trait IUnSafeTradeLogic<TContractState> {
    fn get_unsafe_trade_info(self: @TContractState, order_hash: felt252) -> OrderTradeInfo;
    fn get_unsafe_trades_info(self: @TContractState, order_hashes: Array<felt252>) -> Array<OrderTradeInfo>;
}

#[starknet::component]
mod unsafe_trade_component {

    use kurosawa_akira::RouterComponent::router_component::InternalRoutable;
    use kurosawa_akira::ExchangeBalanceComponent::INewExchangeBalance;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component::InternalExchangeBalanceble;
    use core::{traits::TryInto,option::OptionTrait,array::ArrayTrait};
    use kurosawa_akira::FundsTraits::{PoseidonHash,PoseidonHashImpl,check_sign};
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use starknet::{get_contract_address, ContractAddress, get_block_timestamp};
    use super::{do_taker_price_checks,do_maker_checks,get_feeable_qty,get_limit_px,SignedOrder,Order,OrderTradeInfo,OrderFee,FixedFee,get_gas_fee_and_coin,GasFee};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};

    use kurosawa_akira::RouterComponent::router_component as router_component;
    use router_component::{RoutableImpl};
    use kurosawa_akira::{NonceComponent::INonceLogic,SignerComponent::ISignerLogic,RouterComponent::IRouter};
    use kurosawa_akira::utils::common::DisplayContractAddress;
    
    
    #[storage]
    struct Storage {
        orders_trade_info: LegacyMap::<felt252, OrderTradeInfo>
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        UnsafeTrade: UnsafeTrade,
        RouterReward:RouterReward,
        RouterPunish:RouterPunish,
    }

    #[derive(Drop, starknet::Event)]
    struct UnsafeTrade {
        maker:ContractAddress,
        taker:ContractAddress,
        #[key]
        ticker:(ContractAddress,ContractAddress),
        #[key]
        router:ContractAddress,
        amount_base: u256,
        amount_quote: u256,
        is_sell_side: bool,
        is_failed: bool
    }

    #[derive(Drop, starknet::Event)]
    struct RouterReward {
        #[key]
        router:ContractAddress,
        ticker:(ContractAddress,ContractAddress),
        order_hash:felt252,
        amount:u256,
        taker:ContractAddress,
        is_sell_side: bool,
    }


    #[derive(Drop, starknet::Event)]
    struct RouterPunish {
        #[key]
        router:ContractAddress,
        taker:ContractAddress,
        taker_hash:felt252,
        maker_hash:felt252,
        amount:u256,
    }

    #[embeddable_as(UnSafeTradable)]
    impl UnSafeTradableImpl<TContractState, +HasComponent<TContractState>,+INonceLogic<TContractState>,+balance_component::HasComponent<TContractState>,+router_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>,> of super::IUnSafeTradeLogic<ComponentState<TContractState>> {
        fn get_unsafe_trade_info(self: @ComponentState<TContractState>, order_hash: felt252) -> OrderTradeInfo {
            return self.orders_trade_info.read(order_hash);
        }
        fn get_unsafe_trades_info(self: @ComponentState<TContractState>, mut order_hashes: Array<felt252>) -> Array<OrderTradeInfo> {
            //  Note order hashes must not be empty
            let mut res = ArrayTrait::new();
            loop {
                match order_hashes.pop_front(){
                    Option::Some(order_hash) => {res.append(self.get_unsafe_trade_info(order_hash))}, Option::None(_) => {break();}
                }
            };
            return res; 
        }
        
    }

     #[generate_trait]
    impl InternalUnSafeTradableImpl<TContractState, +HasComponent<TContractState>,+INonceLogic<TContractState>, +balance_component::HasComponent<TContractState>, +router_component::HasComponent<TContractState>, +Drop<TContractState>, +ISignerLogic<TContractState>> of InternalUnSafeTradable<TContractState> {
        // exposed only in contract user
        fn apply_trades_simple(ref self: ComponentState<TContractState>, signed_taker_order:SignedOrder, mut signed_maker_orders:Array<(SignedOrder,u256)>, 
        mut total_amount_matched:u256, gas_price:u256, as_taker_completed:bool, version:u16)  -> bool{
            // Once offchain trading engine yield unsafe trade exchange will push the happened trades ASAP because flow for this trades not safe:
            //  User can revoke allowances
            //  User can not have enough funds at time of settlement
            //  User change validation logic of his signature in his account abstraction

            // so exchange prepare calldata and push the trades with unsafe taker order to contract with coutnerpart maker orders
            // if it happens that order became invalid due aforementioned issues we will punish router and distribute it between exchange and maker:
            //  1) Exchange for wasted gas
            //  2) Maker for lost matched opportunity
            // 
            //  Taker order are simple and dont support STP because it doesnot makes sense
            //  asserts where it is a job of exchange to provide correct data
            //  bool where it is a router job to guarantee correctness
            
            let (exchange, trades):(ContractAddress,u8) = (get_contract_address(), signed_maker_orders.len().try_into().unwrap());
            let taker_order = signed_taker_order.order;
            let taker_hash = taker_order.get_poseidon_hash();
            let mut taker_fill_info = self.orders_trade_info.read(taker_hash);
            
            let upper_bound_taker_give = self._do_part_taker_validate(signed_taker_order, taker_hash, taker_fill_info, trades);
            // prevent exchange trigger reimbure on purpose
            //  else we can send 0 as total_amount_matched and it will trigger failure on checks and trigger router punishment
            //  we need this oracle because we dont know beforehand how much taker will spent because px is protection price
            assert!(total_amount_matched <= upper_bound_taker_give, "WRONG_AMOUNT_MATCHED_ORACLE");
                        
            // TODO bit dumb that it fires exception, how reimburse in that case? cause custom contract can force fails on signature validation
            let (mut amount_out, _) = if check_sign(taker_order.maker, taker_hash, signed_taker_order.router_sign) {
                            self._prepare_taker(taker_order, total_amount_matched, exchange, trades, gas_price)  } 
                    else {
                        (0,0)
            };
            let (mut balancer, taker_fees) = (self.get_balancer_mut(), taker_order.fee);

            let fee_recipient = balancer.fee_recipient.read();
            assert!(taker_order.fee.trade_fee.recipient == fee_recipient, "WRONG_TAKER_FEE_RECIPIENT: expected {}, got {}", fee_recipient, taker_order.fee.trade_fee.recipient);
            assert!(taker_order.version == version, "WRONG_TAKER_VERSION");

            let failed = amount_out == 0;
            let mut taker_received = 0;
            loop {
                match signed_maker_orders.pop_front(){
                    Option::Some((signed_maker_order, oracle_settle_qty)) => {
                        let maker_order = signed_maker_order.order;
                        let (settle_px, amount_quote, amount_base, mut maker_fill_info, maker_hash) = 
                                    self._do_maker_checks_and_common(signed_maker_order, taker_order, taker_fill_info, oracle_settle_qty);
                        assert!(maker_order.fee.trade_fee.recipient == fee_recipient, "WRONG_MAKER_FEE_RECIPIENT: expected {}, got {}", fee_recipient, maker_order.fee.trade_fee.recipient);
                        assert!(maker_order.version == version, "WRONG_TAKER_VERSION");
                        if failed {
                            self.punish_router_simple(taker_fees.gas_fee, taker_fees.router_fee.recipient, 
                                        signed_maker_order.order.maker, taker_order.maker, gas_price, taker_hash, maker_hash);
                        } else {
                            balancer.rebalance_after_trade(maker_order.maker, 
                                    taker_order.maker, taker_order.ticker, amount_base, amount_quote, maker_order.flags.is_sell_side);
                            balancer.apply_maker_fee(maker_order.maker, maker_order.fee.trade_fee, maker_order.flags.is_sell_side,
                                    maker_order.ticker, amount_base, amount_quote);

                            if taker_order.flags.is_sell_side { amount_out -= amount_base; taker_received += amount_quote;
                            } else { amount_out -= amount_quote; taker_received += amount_base;}
                        }    
                        maker_fill_info.filled_amount += amount_base;
                        taker_fill_info.filled_amount += amount_base;
                        maker_fill_info.last_traded_px = settle_px;
                        taker_fill_info.last_traded_px = settle_px;
                        
                        
                        self.orders_trade_info.write(maker_hash, maker_fill_info);
                        self.emit(UnsafeTrade{
                            maker:signed_maker_order.order.maker, taker:taker_order.maker, ticker:taker_order.ticker,
                            router:taker_order.fee.router_fee.recipient,
                            amount_base, amount_quote, is_sell_side: !taker_order.flags.is_sell_side, is_failed:failed
                        });
                               
                    },
                    Option::None(_) => { 
                        if failed {
                            taker_fill_info.filled_amount = taker_order.quantity;
                            self.orders_trade_info.write(taker_hash, taker_fill_info);
                        } else {
                            taker_fill_info.num_trades_happened += trades;
                            self.orders_trade_info.write(taker_hash, taker_fill_info);
                        }
                        break();
                    }
                }
            };

            taker_fill_info.as_taker_completed = as_taker_completed;
            self.orders_trade_info.write(taker_hash, taker_fill_info);
            if failed { return false;}

            // do the reward and pay for the gas, we accumulate all and consume at once, avoiding repetitive actions
            self.finalize_taker(taker_order, taker_hash, taker_received, amount_out, exchange, gas_price, trades);  

            return true;     
        }


        fn _do_part_taker_validate(self:@ComponentState<TContractState>, signed_taker_order:SignedOrder, taker_hash:felt252, taker_fill_info:OrderTradeInfo, trades:u8) -> u256 {
            //Returns max user can actually spend
            let router = self.get_router();
            let taker_order = signed_taker_order.order;

            //Validate router, job of exchange because of this assert
            assert!(router.validate_router(taker_hash, signed_taker_order.router_sign, 
                    taker_order.router_signer, taker_order.fee.router_fee.recipient), "WRONG_ROUTER_SIGN");
            
            let remaining_taker_amount = taker_order.quantity - taker_fill_info.filled_amount;
            assert!(remaining_taker_amount > 0, "WRONG_TAKER_AMOUNT");
        
            assert!(!taker_order.flags.post_only, "WRONG_TAKER_FLAG: post_only must be False");
            assert!(taker_order.number_of_swaps_allowed >= taker_fill_info.num_trades_happened + trades, "HIT_SWAPS_ALLOWED: allowed {}, got {}", taker_order.number_of_swaps_allowed, taker_fill_info.num_trades_happened + trades);    
            assert!(!taker_fill_info.as_taker_completed, "Taker order {} marked completed", taker_hash);
            assert!(get_block_timestamp() < taker_order.expire_at.into(), "Taker order expire {}", taker_order.expire_at);

            if signed_taker_order.order.flags.is_sell_side {remaining_taker_amount} else {remaining_taker_amount * signed_taker_order.order.price}
        }


        fn _do_maker_checks_and_common(ref self:ComponentState<TContractState>,signed_maker_order:SignedOrder,taker_order:Order,taker_fill_info:OrderTradeInfo,oracle_settle_qty:u256)->(u256,u256,u256,OrderTradeInfo,felt252) {
            let contract  = self.get_contract();
            let (maker_order, (r,s)) = (signed_maker_order.order, signed_maker_order.sign);
            let maker_hash = maker_order.get_poseidon_hash();
            let mut maker_fill_info = self.orders_trade_info.read(maker_hash);
            // check sign                         
            assert!(contract.check_sign(maker_order.maker, maker_hash, r, s), "WRONG_SIGN_MAKER: (maker_hash, r, s): ({}, {}, {})", maker_hash, r, s);
            do_maker_checks(maker_order, maker_fill_info, contract.get_nonce(maker_order.maker));                                
            // additional check
            assert!(maker_order.flags.post_only, "MAKER_ONLY_POST_ONLY");
                        
            let (settle_px, maker_qty) = get_limit_px(maker_order, maker_fill_info);
                        
            let taker_qty = do_taker_price_checks(taker_order, settle_px, taker_fill_info);
                        
            let mut settle_base_amount = if maker_qty > taker_qty {taker_qty} else {maker_qty};
            if oracle_settle_qty > 0 {
                assert!(oracle_settle_qty <= settle_base_amount, "WRONG_ORACLE_SETTLE_QTY {} for {}", oracle_settle_qty, maker_hash);
                settle_base_amount = oracle_settle_qty; 
            }


                    
            assert!(taker_order.flags.is_sell_side != maker_order.flags.is_sell_side, "WRONG_SIDE");
            assert!(taker_order.ticker == maker_order.ticker ,"MISMATCH_TICKER");
            assert!(taker_order.flags.to_safe_book == maker_order.flags.to_safe_book && !taker_order.flags.to_safe_book, "WRONG_BOOK_DESTINATION");
            assert!(taker_order.base_asset == maker_order.base_asset, "WRONG_ASSET_AMOUNT");
                            
            let settle_quote_amount = settle_px * settle_base_amount / maker_order.base_asset;
            assert!(settle_quote_amount > 0, "0_MATCHING_COST");
            return (settle_px, settle_quote_amount, settle_base_amount, maker_fill_info, maker_hash);

        }

        fn _prepare_taker(ref self:ComponentState<TContractState>, taker_order:Order, mut out_amount:u256, exchange:ContractAddress,swaps:u8,
                            gas_price:u256) ->(u256,u256) {
            //Checks that user have:
            //  required allowance of out token that he about to spend
            //  required amount of out token that he about to spent
            //  required amount for gas for swaps beforehand
            //  if fails returns 0 else amount that we minted on exchange for him, at the end of execution we return unspent amount back to user

            let (base, quote) = (taker_order.ticker);
            let mut balancer = self.get_balancer_mut();

            
            let (erc20_base, erc20_quote) = (IERC20Dispatcher{contract_address:base}, IERC20Dispatcher{contract_address:quote});
            let (spent_gas, gas_coin) = get_gas_fee_and_coin(taker_order.fee.gas_fee, gas_price, balancer.wrapped_native_token.read());

            let (erc, taker_out_balance, taker_out_allowance, mut out_token) = if taker_order.flags.is_sell_side {
                (erc20_base, erc20_base.balanceOf(taker_order.maker), erc20_base.allowance(taker_order.maker, exchange), base)
            } else {
                (erc20_quote, erc20_quote.balanceOf(taker_order.maker), erc20_quote.allowance(taker_order.maker, exchange), quote)
            };
            
            let spent_gas = spent_gas * swaps.into();
            let trade_amount = out_amount;

            if gas_coin == out_token { out_amount += spent_gas;
            } else {
                let gas_erc = IERC20Dispatcher{contract_address:gas_coin};
                if gas_erc.allowance(taker_order.maker, exchange) < spent_gas {return (0,0);}
                if gas_erc.balanceOf(taker_order.maker) < spent_gas {return (0,0);}
            }
        
            if taker_out_balance < out_amount  { return (0,0);}
            if taker_out_allowance < out_amount {return (0,0);}

            let exchange_balance = erc.balanceOf(exchange);
            erc.transferFrom(taker_order.maker, exchange, out_amount);
            
            assert!(erc.balanceOf(exchange) - exchange_balance == out_amount, "FEW_TRANSFERRED: expected {}, got {}", out_amount, erc.balanceOf(exchange) - exchange_balance);

            if gas_coin != out_token {
                let gas_erc = IERC20Dispatcher{contract_address:gas_coin};
                let exchange_balance = gas_erc.balanceOf(exchange);
                gas_erc.transferFrom(taker_order.maker, exchange, spent_gas);
                assert!(gas_erc.balanceOf(exchange) - exchange_balance ==  spent_gas, "FEW_GAS_TRANSFERRED: expected {}, got {}", spent_gas, gas_erc.balanceOf(exchange) - exchange_balance);

                balancer.mint(taker_order.maker, spent_gas, gas_coin);
            }

            balancer.mint(taker_order.maker, out_amount, out_token);
            
            return (trade_amount, spent_gas);
        }

        fn finalize_taker(ref self:ComponentState<TContractState>, taker_order:Order,taker_hash:felt252, received_amount:u256, unspent_amount:u256, exchange:ContractAddress,gas_price:u256, trades:u8) {
            // pay for gas
            // Reward router
            // Transfer unspent amounts to the user back
            let (router_fee, exchange_fee) = (taker_order.fee.router_fee,taker_order.fee.trade_fee);
            let (mut balancer, mut router) = (self.get_balancer_mut(),self.get_router_mut());

            // do the gas tfer
            let (spent, gas_coin) = super::get_gas_fee_and_coin(taker_order.fee.gas_fee, gas_price, balancer.wrapped_native_token.read());
            let spent = spent * trades.into();
            balancer.internal_transfer(taker_order.maker, balancer.fee_recipient.read(), spent, gas_coin);
            

            let fee_token = if taker_order.flags.is_sell_side {let (b,q) = taker_order.ticker; q} else {let (b,q) = taker_order.ticker;b};
            
            let router_fee_amount = get_feeable_qty(router_fee, received_amount, false);
            if router_fee_amount > 0 {
                balancer.burn(taker_order.maker, router_fee_amount, fee_token);
                router.mint(router_fee.recipient, fee_token, router_fee_amount);
                self.emit(
                    RouterReward{ router:router_fee.recipient, ticker:taker_order.ticker, order_hash:taker_hash, 
                                    amount:router_fee_amount, taker:taker_order.maker, is_sell_side:!taker_order.flags.is_sell_side
                });
            }

            let exchange_fee_amount = get_feeable_qty(exchange_fee, received_amount, false);
            if exchange_fee_amount > 0 {
                balancer.internal_transfer(taker_order.maker, exchange_fee.recipient, exchange_fee_amount, fee_token);
            }

            let received_amount  = received_amount - router_fee_amount - exchange_fee_amount;
            if received_amount > 0 {
                let erc = IERC20Dispatcher {contract_address:fee_token};
                let balance = erc.balanceOf(exchange);
                erc.transfer(taker_order.maker, received_amount);
                balancer.burn(taker_order.maker, received_amount, fee_token);
                assert!(balance - erc.balanceOf(exchange) >= received_amount, "OUT_TFER_ERROR");
            }
            if unspent_amount > 0 {
                let token = if !taker_order.flags.is_sell_side {let (b,q) = taker_order.ticker; q} else {let (b,q) = taker_order.ticker;b};
                let erc = IERC20Dispatcher {contract_address:token};
                let balance = erc.balanceOf(exchange);
                erc.transfer(taker_order.maker, unspent_amount);
                balancer.burn(taker_order.maker, unspent_amount, token);
                assert!(balance - erc.balanceOf(exchange) >= unspent_amount, "IN_TFER_ERROR");
            }
        }
      

        fn punish_router_simple(ref self: ComponentState<TContractState>,gas_fee:GasFee,router_addr:ContractAddress, 
                    maker:ContractAddress, taker:ContractAddress, gas_px:u256,taker_hash:felt252,maker_hash:felt252) {
            let (mut balancer, mut router) = (self.get_balancer_mut(), self.get_router_mut());
            let native_base_token = balancer.get_wrapped_native_token();
            let charged_fee = gas_fee.gas_per_action.into() * gas_px * router.get_punishment_factor_bips().into() / 10000;
            if charged_fee == 0 {return;}
            
            router.burn(router_addr, native_base_token, 2 * charged_fee);
            balancer.mint(balancer.fee_recipient.read(), charged_fee, native_base_token);
            balancer.mint(maker, charged_fee, native_base_token);

            self.emit(RouterPunish{router:router_addr, taker, taker_hash, maker_hash, amount: 2 * charged_fee});
        }
    }

    // this (or something similar) will potentially be generated in the next RC
    #[generate_trait]
    impl GetBalancer<
        TContractState,
        +HasComponent<TContractState>,
        +balance_component::HasComponent<TContractState>,
        +Drop<TContractState>> of GetBalancerTrait<TContractState> {
        fn get_balancer(
            self: @ComponentState<TContractState>
        ) -> @balance_component::ComponentState<TContractState> {
            let contract = self.get_contract();
            balance_component::HasComponent::<TContractState>::get_component(contract)
        }

        fn get_balancer_mut(
            ref self: ComponentState<TContractState>
        ) -> balance_component::ComponentState<TContractState> {
            let mut contract = self.get_contract_mut();
            balance_component::HasComponent::<TContractState>::get_component_mut(ref contract)
        }
    }

        // this (or something similar) will potentially be generated in the next RC
    #[generate_trait]
    impl GetRouter<
        TContractState,
        +HasComponent<TContractState>,
        +router_component::HasComponent<TContractState>,
        +Drop<TContractState>> of GetRouterTrait<TContractState> {
        fn get_router(
            self: @ComponentState<TContractState>
        ) -> @router_component::ComponentState<TContractState> {
            let contract = self.get_contract();
            router_component::HasComponent::<TContractState>::get_component(contract)
        }

        fn get_router_mut(
            ref self: ComponentState<TContractState>
        ) -> router_component::ComponentState<TContractState> {
            let mut contract = self.get_contract_mut();
            router_component::HasComponent::<TContractState>::get_component_mut(ref contract)
        }
    }
}