use kurosawa_akira::Order::{SignedOrder,Order,validate_maker_order,validate_taker_order,OrderTradeInfo,OrderFee,FixedFee,
            get_feeable_qty,get_limit_px,do_taker_price_checks,do_maker_checks,get_gas_fee_and_coin,GasFee};

#[starknet::interface]
trait IUnSafeTradeLogic<TContractState> {
}

#[starknet::component]
mod unsafe_trade_component {
    use kurosawa_akira::ExchangeBalanceComponent::INewExchangeBalance;
use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component::InternalExchangeBalanceble;
    use core::{traits::TryInto,option::OptionTrait,array::ArrayTrait};
    use kurosawa_akira::FundsTraits::{PoseidonHash,PoseidonHashImpl,check_sign};
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use kurosawa_akira::{NonceComponent::INonceLogic,SignerComponent::ISignerLogic,RouterComponent::IRouter};
    
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use starknet::{get_contract_address,ContractAddress};
    use super::{do_taker_price_checks,do_maker_checks,get_feeable_qty,get_limit_px,SignedOrder,Order,validate_maker_order,validate_taker_order,OrderTradeInfo,OrderFee,FixedFee,get_gas_fee_and_coin,GasFee};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};

    use kurosawa_akira::RouterComponent::router_component as router_component;
    use router_component::{RoutableImpl};
    
    
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
        #[key]
        maker:ContractAddress,
        #[key]
        taker:ContractAddress,
        #[key]
        ticker:(ContractAddress,ContractAddress),
        #[key]
        router:ContractAddress,
        amount_base: u256,
        amount_quote: u256,
        is_sell_side: bool,
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
        #[key]
        taker:ContractAddress,
        taker_hash:felt252,
        maker_hash:felt252,
        amount:u256,
    }



    #[embeddable_as(UnSafeTradable)]
    impl UnSafeTradableImpl<TContractState, +HasComponent<TContractState>,+INonceLogic<TContractState>,+router_component::HasComponent<TContractState>,+balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of super::IUnSafeTradeLogic<ComponentState<TContractState>> {

    }

     #[generate_trait]
    impl InternalSafeTradableImpl<TContractState, +HasComponent<TContractState>,+INonceLogic<TContractState>,
    +balance_component::HasComponent<TContractState>,+router_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>,+IRouter<TContractState>> of InternalSafeTradable<TContractState> {

        // exposed only in contract user
        fn apply_trades_simple(ref self: ComponentState<TContractState>, signed_taker_order:SignedOrder, mut signed_maker_orders:Array<SignedOrder>, total_amount_matched:u256, gas_price:u256) {
            let (exchange, trades) = (get_contract_address(), signed_maker_orders.len().try_into().unwrap());
            let (contract, taker_order) = (self.get_contract(), signed_taker_order.order);
            let taker_hash = taker_order.get_poseidon_hash();
            let mut taker_fill_info = self.orders_trade_info.read(taker_hash);

            self._do_part_taker_validate(signed_taker_order, taker_hash, taker_fill_info, trades);
            
            let (mut amount_out, gas_spent) = self._prepare_taker(taker_order, total_amount_matched, exchange, trades, gas_price, total_amount_matched);
            
            if amount_out == 0 { // if failed by malicious activity by exchange or router
                loop {
                    match signed_maker_orders.pop_front(){
                        Option::Some(signed_maker_order) => {
                            let (settle_px, matching_cost, settle_qty, maker_fill_info, maker_hash) = 
                                        self._do_maker_checks_and_common(signed_maker_order, taker_order, taker_fill_info);
                            self.punish_router_simple(taker_order.fee.gas_fee, taker_order.fee.router_fee.recipient, 
                                        exchange, signed_maker_order.order.maker, gas_price);
                        },
                        Option::None(_) => { 
                            // invalidate this order so exchange cant send it multiple times
                            taker_fill_info.filled_amount = taker_order.quantity;
                            break();
                        }
                    }
                };
                return;
            }            
            
            let mut taker_received = 0;
            loop {
                match signed_maker_orders.pop_front(){
                    Option::Some(signed_maker_order) => {
                        let (settle_px, matching_cost, settle_qty, mut maker_fill_info, maker_hash) = 
                                    self._do_maker_checks_and_common(signed_maker_order, taker_order, taker_fill_info);
                        
                        self.rebalance_after_trade(signed_maker_order.order, taker_order, matching_cost, settle_qty);
                        self.apply_maker_fee(signed_maker_order.order, matching_cost, settle_qty);                        
                        
                        maker_fill_info.filled_amount += settle_qty;
                        taker_fill_info.filled_amount += settle_qty;
                        if taker_order.flags.is_sell_side {
                            amount_out -= settle_qty;
                            taker_received += matching_cost;
                        } else {
                            amount_out -= matching_cost;
                            taker_received += settle_qty;
                        }

                        self.emit(UnsafeTrade{
                            maker:signed_maker_order.order.maker,taker:taker_order.maker, ticker:taker_order.ticker,
                            router:taker_order.fee.router_fee.recipient,
                            amount_base:settle_qty,amount_quote:settle_qty, is_sell_side: !taker_order.flags.is_sell_side  
                        });
                               
                    },
                    Option::None(_) => { break();}
                }
            };

            taker_fill_info.num_trades_happened += trades;
            self.orders_trade_info.write(taker_hash, taker_fill_info);

            // do the reward
            self.finalize_taker(taker_order,taker_hash, taker_received, amount_out, exchange, gas_price);       
        }


        // }

        fn _do_part_taker_validate(self:@ComponentState<TContractState>, signed_taker_order:SignedOrder, taker_hash:felt252, taker_fill_info:OrderTradeInfo, trades:u8) {
            let contract = self.get_contract();
            let taker_order = signed_taker_order.order;
            // TODO bit dumb that it fires exception, how reimburse in that case?
            assert(check_sign(taker_order.maker, taker_hash, signed_taker_order.router_sign), 'TODO_FAILS');

            // Validate router
            assert(contract.validate_router(taker_hash, signed_taker_order.router_sign, 
                    taker_order.router_signer, taker_order.fee.router_fee.recipient),'WRONG_ROUTER_SIGN');
            
            let remaining_taker_amount = taker_order.quantity - taker_fill_info.filled_amount;
            assert(remaining_taker_amount > 0, 'WRONG_TAKER_AMOUNT');
        
            assert(!taker_order.flags.post_only, 'WRONG_TAKER_FLAG');
            assert(taker_order.number_of_swaps_allowed >= taker_fill_info.num_trades_happened + trades, 'HIT_SWAPS_ALLOWED');    
        }

        fn _do_maker_checks_and_common(ref self:ComponentState<TContractState>,signed_maker_order:SignedOrder,taker_order:Order,taker_fill_info:OrderTradeInfo)->(u256,u256,u256,OrderTradeInfo,felt252) {
            let contract  = self.get_contract();
            let (maker_order, (r,s)) = (signed_maker_order.order, signed_maker_order.sign);
            let maker_hash = maker_order.get_poseidon_hash();
            let mut maker_fill_info = self.orders_trade_info.read(maker_hash);
            // check sign                         
            assert(contract.check_sign(maker_order.maker, maker_hash, r, s), 'WRONG_SIGN_MAKER');
            do_maker_checks(maker_order, maker_fill_info, contract.get_nonce(maker_order.maker));                                
            // additional check
            assert(maker_order.flags.post_only, 'MAKER_ONLY_POST_ONLY');
                        
            let (settle_px, maker_qty) = get_limit_px(maker_order, maker_fill_info);
                        
            let taker_qty = do_taker_price_checks(taker_order, settle_px, taker_fill_info);
                        
            let settle_qty = if maker_qty > taker_qty {taker_qty} else {maker_qty};
            assert(taker_order.ticker == maker_order.ticker ,'MISMATCH_TICKER');
            assert(taker_order.flags.to_safe_book == maker_order.flags.to_safe_book && !taker_order.flags.to_safe_book, 'WRONG_BOOK_DESTINATION');
            assert(taker_order.base_asset == maker_order.base_asset, 'WRONG_ASSET_AMOUNT');
                            
            let matching_cost = settle_px * settle_qty / maker_order.base_asset;
            assert(matching_cost > 0, '0_MATCHING_COST');
            return (settle_px, matching_cost, settle_qty, maker_fill_info, maker_hash);

        }

        fn _prepare_taker(ref self:ComponentState<TContractState>, taker_order:Order, mut out_amount:u256, exchange:ContractAddress,swaps:u8,
                            gas_price:u256, total_amount_matched:u256) ->(u256,u256) {
            //Checks that user have:
            //  required allowance of out token that he about to spend
            //  required amount of out token that he about to spent
            //  required amount for gas for swaps beforehand
            //  if fails returns 0 else amount that we minted on exchange for him, at the end of execution we return unspent amount back to user

            let (base, quote) = (taker_order.ticker);
            let mut balancer = self.get_balancer_mut();
            
            let (erc20_base, erc20_quote) = (IERC20Dispatcher{contract_address:base}, IERC20Dispatcher{contract_address:quote});
            let (spent_gas, gas_coin) = get_gas_fee_and_coin(taker_order.fee.gas_fee, gas_price, balancer.wrapped_native_token.read());

            let (erc,taker_out_balance, taker_out_allowance, mut out_token) = if taker_order.flags.is_sell_side {
                (erc20_base, erc20_base.balanceOf(taker_order.maker), erc20_base.allowance(taker_order.maker, exchange), base)
            } else {
                (erc20_quote, erc20_quote.balanceOf(taker_order.maker), erc20_quote.allowance(taker_order.maker, exchange), quote)
            };
            
            let spent_gas = spent_gas * swaps.into();
            let trade_amount = out_amount;

            if gas_coin == out_token {
                out_amount += spent_gas;
            } else {
                let gas_erc = IERC20Dispatcher{contract_address:gas_coin};
                if gas_erc.allowance(taker_order.maker, exchange) < spent_gas {return (0,0);}
                if gas_erc.balanceOf(taker_order.maker) < spent_gas {return (0,0);}
            }
        
            if taker_out_balance < out_amount  { return (0,0);}
            if taker_out_allowance < out_amount {return (0,0);}

            let exchange_balance = erc.balanceOf(exchange);
            erc.transferFrom(taker_order.maker, exchange, out_amount);
            assert(erc.balanceOf(exchange) == exchange_balance, 'FEW_TRANSFERRED');

            if gas_coin != out_token {
                let gas_erc = IERC20Dispatcher{contract_address:gas_coin};
                let exchange_balance = gas_erc.balanceOf(exchange);
                gas_erc.transferFrom(taker_order.maker, exchange, spent_gas);
                assert(gas_erc.balanceOf(exchange) == exchange_balance, 'FEW_GAS_TRANSFERRED');

                balancer.mint(taker_order.maker, spent_gas, gas_coin);
            }

            balancer.mint(taker_order.maker, out_amount, out_token);
            return (trade_amount, spent_gas);
        }

        fn finalize_taker(ref self:ComponentState<TContractState>, taker_order:Order,taker_hash:felt252, received_amount:u256,unspent_amount:u256, exchange:ContractAddress,gas_price:u256) {
            // pay for gas
            // Reward router
            // Transfer unspent amounts to the user back
            let (router_fee, exhcange_fee) = (taker_order.fee.router_fee,taker_order.fee.trade_fee);
            let (mut balancer, mut router,contract) = (self.get_balancer_mut(),self.get_router_mut(), self.get_contract());

            // do the gas tfer
            let (spent, gas_coin) = super::get_gas_fee_and_coin(taker_order.fee.gas_fee, gas_price, balancer.wrapped_native_token.read());
            balancer.internal_transfer(taker_order.maker, balancer.fee_recipient.read(), spent, gas_coin);
            

            let fee_token = if taker_order.flags.is_sell_side {let (b,q) = taker_order.ticker; q} else {let (b,q) = taker_order.ticker;b};
            
            let router_fee_amount = get_feeable_qty(router_fee, received_amount, false);
            if router_fee_amount > 0 {
                balancer.burn(taker_order.maker, router_fee_amount, fee_token);
                let cur_balance = router.token_to_user.read((fee_token,router_fee.recipient));
                router.token_to_user.write((fee_token, router_fee.recipient), cur_balance + router_fee_amount);
                self.emit(
                    RouterReward{ router:router_fee.recipient, ticker:taker_order.ticker, order_hash:taker_hash, 
                                    amount:router_fee_amount, taker:taker_order.maker, is_sell_side:!taker_order.flags.is_sell_side
                });
            }

            let exchange_fee_amount = get_feeable_qty(exhcange_fee, received_amount, false);
            if exchange_fee_amount > 0 {
                balancer.internal_transfer(taker_order.maker, exhcange_fee.recipient, exchange_fee_amount, fee_token);
            }

            let received_amount  = received_amount - router_fee_amount - exchange_fee_amount;
            if received_amount > 0 {
                let erc = IERC20Dispatcher {contract_address:fee_token};
                let balance = erc.balanceOf(exchange);
                erc.transfer(taker_order.maker, received_amount);
                assert(balance - erc.balanceOf(exchange) >= received_amount, 'OUT_TFER_ERROR');
            }
            if unspent_amount > 0 {
                let token = if !taker_order.flags.is_sell_side {let (b,q) = taker_order.ticker; q} else {let (b,q) = taker_order.ticker;b};
                let erc = IERC20Dispatcher {contract_address:token};
                let balance = erc.balanceOf(exchange);
                erc.transfer(taker_order.maker, unspent_amount);
                assert(balance - erc.balanceOf(exchange) >= unspent_amount, 'IN_TFER_ERROR');
            }
        }
      


        fn rebalance_after_trade(
            ref self: ComponentState<TContractState>,
            maker_order:Order, taker_order:Order,amount_base:u256,amount_quote:u256,
        ) {
            let (mut balancer, (base, quote)) = (self.get_balancer_mut(), maker_order.ticker);

            if maker_order.flags.is_sell_side{ // BASE/QUOTE -> maker sell BASE for QUOTE
                assert(balancer.balanceOf(base, maker_order.maker) >= amount_base, 'FEW_BALANCE_MAKER');
                assert(balancer.balanceOf(quote, taker_order.maker) >= amount_quote, 'FEW_BALANCE_TAKER');
                balancer.internal_transfer(maker_order.maker,taker_order.maker, amount_base, base);
                balancer.internal_transfer(taker_order.maker, maker_order.maker, amount_quote, quote);
            }
            else { // BASE/QUOTE -> maker buy BASE for QUOTE
                assert(balancer.balanceOf(quote, taker_order.maker) >= amount_quote, 'FEW_BALANCE_MAKER');
                assert(balancer.balanceOf(base,  maker_order.maker) >= amount_base, 'FEW_BALANCE_TAKER');
                balancer.internal_transfer(maker_order.maker, taker_order.maker, amount_quote, quote);
                balancer.internal_transfer(taker_order.maker, maker_order.maker, amount_base, base);
            }
        }

        fn apply_maker_fee(ref self: ComponentState<TContractState>, maker_order:Order, base_amount:u256,quote_amount:u256) {
            let mut balancer = self.get_balancer_mut();
            let fee = maker_order.fee.trade_fee;
            let maker_fee_token = if maker_order.flags.is_sell_side { let (b,q) = maker_order.ticker; b } else {let (b,q) = maker_order.ticker; q};
            let maker_fee_amount = get_feeable_qty(fee, if maker_order.flags.is_sell_side { quote_amount } else {base_amount}, true);
            assert(maker_order.fee.router_fee.taker_pbips == 0, 'MAKER_SAFE_REQUIRES_NO_ROUTER');
            
            if maker_fee_amount > 0 {
                balancer.internal_transfer(maker_order.maker, fee.recipient, maker_fee_amount, maker_fee_token);
            }
        }
       

        fn punish_router_simple(ref self: ComponentState<TContractState>,gas_fee:GasFee,router_addr:ContractAddress, exchange:ContractAddress, maker:ContractAddress, gas_px:u256) {
            let mut balancer = self.get_balancer_mut();
            let mut router = self.get_router_mut();
            let native_base_token = balancer.get_wrapped_native_token();
            let charged_fee = gas_fee.gas_per_action.into() * gas_px * router.get_punishment_factor_bips() / 10000;
            if charged_fee == 0 {return;}
            let router_balance = router.token_to_user.read((native_base_token, router_addr));
            router.token_to_user.write((native_base_token, router_addr), router_balance - 2 * charged_fee);
            balancer.mint(exchange,charged_fee,native_base_token);
            balancer.mint(maker, charged_fee, native_base_token);
            // emit event about charge
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