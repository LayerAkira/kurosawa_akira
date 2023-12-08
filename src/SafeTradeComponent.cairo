use kurosawa_akira::Order::{SignedOrder,Order,validate_maker_order,validate_taker_order,OrderTradeInfo,OrderFee,FixedFee,
            get_feeable_qty,get_limit_px,do_taker_price_checks,do_maker_checks};

#[starknet::interface]
trait ISafeTradeLogic<TContractState> {
    fn get_safe_trade_info(self: @TContractState, order_hash: felt252) -> OrderTradeInfo;
}

#[starknet::component]
mod safe_trade_component {
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component::InternalExchangeBalanceble;
    use core::{traits::TryInto,option::OptionTrait,array::ArrayTrait};
    use kurosawa_akira::FundsTraits::{PoseidonHash,PoseidonHashImpl};
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use kurosawa_akira::{NonceComponent::INonceLogic,SignerComponent::ISignerLogic};
    
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use starknet::{get_contract_address,ContractAddress};
    use super::{do_taker_price_checks,do_maker_checks,get_feeable_qty,get_limit_px,SignedOrder,Order,validate_maker_order,validate_taker_order,OrderTradeInfo,OrderFee,FixedFee};

    #[storage]
    struct Storage {
        orders_trade_info: LegacyMap::<felt252, OrderTradeInfo>,
        last_taker_order_and_foc:(felt252,bool,u256),
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Trade: Trade,
    }

    #[derive(Drop, starknet::Event)]
    struct Trade {
        #[key]
        maker:ContractAddress,
        #[key]
        taker:ContractAddress,
        #[key]
        ticker:(ContractAddress,ContractAddress),
        amount_base: u256,
        amount_quote: u256,
        is_sell_side: bool,
    }

    #[embeddable_as(SafeTradable)]
    impl SafeTradableImpl<TContractState, +HasComponent<TContractState>,+INonceLogic<TContractState>,+balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of super::ISafeTradeLogic<ComponentState<TContractState>> {
        fn get_safe_trade_info(self: @ComponentState<TContractState>, order_hash: felt252) -> OrderTradeInfo {
            return self.orders_trade_info.read(order_hash);
        }
    }

     #[generate_trait]
    impl InternalSafeTradableImpl<TContractState, +HasComponent<TContractState>,+INonceLogic<TContractState>,
    +balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of InternalSafeTradable<TContractState> {

        // exposed only in contract user
        fn apply_trades(ref self: ComponentState<TContractState>,mut taker_orders:Array<SignedOrder>, mut maker_orders:Array<SignedOrder>, mut iters:Array<(u8,bool)>,gas_price:u256) {
            let mut maker_order = *maker_orders.at(0).order;
            let mut maker_hash:felt252  = 0.try_into().unwrap();  
            let mut maker_fill_info = self.orders_trade_info.read(maker_hash);
            let (contract, balance) = (self.get_contract(), self.get_balancer_mut());
            
            let (_, use_prev_maker) = *iters.at(0);
            let mut first_iter = true;
            assert(!use_prev_maker, 'WRONG_FIRST_ITER');
            let (mut total_matching_cost, mut total_qty) = (0,0);
            loop {
                match iters.pop_front(){
                    Option::Some((trades ,mut use_prev_maker)) => {
                        let signed_taker_order = taker_orders.pop_front().unwrap();
                        let (taker_order, taker_hash, mut taker_fill_info) =  self.part_vaidate_taker(signed_taker_order, trades); 
                        let mut cur = 0;
                        loop {
                            if cur == trades { break();}

                            if !use_prev_maker {
                                // update state for maker that gone (edge case if )
                                if first_iter { first_iter = false;
                                } else {
                                    self.orders_trade_info.write(maker_hash, maker_fill_info);
                                }

                                //  pop new one do sign check  and update variables
                                let signed_order = maker_orders.pop_front().unwrap();
                                maker_hash =  signed_order.order.get_poseidon_hash();
                                maker_order = signed_order.order;
                                maker_fill_info =  self.orders_trade_info.read(maker_hash);

                                do_maker_checks(maker_order, maker_fill_info, contract.get_nonce(maker_order.maker));
                                let (r,s) = signed_order.sign;
                                assert(contract.check_sign(signed_order.order.maker, maker_hash, r, s), 'WRONG_SIGN_MAKER');
                                
                                use_prev_maker = false;
                            } else {
                                assert(maker_fill_info.filled_amount - maker_order.quantity > 0, 'MAKER_ALREADY_FILLED');
                            }

                            let (settle_px, maker_qty) = get_limit_px(maker_order, maker_fill_info);
                            
                            let taker_qty = do_taker_price_checks(taker_order, settle_px, taker_fill_info);
                            let settle_qty = if maker_qty > taker_qty {taker_qty} else {maker_qty};
                            assert(taker_order.ticker == maker_order.ticker,'MISMATCH_TICKER');
                            assert(taker_order.flags.to_safe_book == maker_order.flags.to_safe_book && taker_order.flags.to_safe_book, 'WRONG_BOOK_DESTINATION');
                            assert(taker_order.base_asset == maker_order.base_asset, 'WRONG_ASSET_AMOUNT');
                            let matching_cost = settle_px * settle_qty / maker_order.base_asset;
                            assert(matching_cost > 0, '0_MATCHING_COST');
                            
                            self.settle_trade(maker_order, taker_order, matching_cost, settle_qty, gas_price);
                            maker_fill_info.filled_amount += settle_qty;
                            taker_fill_info.filled_amount += settle_qty;
                            cur += 1;
                        };

                        self.last_taker_order_and_foc.write((taker_hash, taker_order.flags.full_fill_only, taker_order.quantity - taker_fill_info.filled_amount));
                        
                        taker_fill_info.num_trades_happened += trades;
                        self.orders_trade_info.write(taker_hash, taker_fill_info);

                        // pay for gas and give exhcange here

                    },
                    Option::None(_) => {
                        assert (taker_orders.len() == 0 && maker_orders.len() == 0 && iters.len() == 0, 'MISMATCH');
                        // update state for maker that gone
                        self.orders_trade_info.write(maker_hash, maker_fill_info);
                        break();
                    }
                }
            };
        }

        fn part_vaidate_taker(self: @ComponentState<TContractState>,taker_signed_order:SignedOrder, taker_times:u8) -> (Order,felt252,OrderTradeInfo) {
            let (contract,taker_order,(r,s)) = (self.get_contract(),taker_signed_order.order,taker_signed_order.sign);
            let taker_order_hash = taker_order.get_poseidon_hash();
            let taker_fill_info = self.orders_trade_info.read(taker_order_hash);
            
            assert(contract.check_sign(taker_order.maker, taker_order_hash, r, s), 'WRONG_SIGN_TAKER');
            assert(taker_order.number_of_swaps_allowed > taker_fill_info.num_trades_happened + taker_times, 'HIT_SWAPS_ALLOWED');
            assert(!taker_order.flags.post_only, 'WRONG_TAKER_FLAG');
            assert(taker_order.nonce >= contract.get_nonce(taker_order.maker),'OLD_TAKER_NONCE');

            let (last_fill_taker_hash, is_foc, remaining):(felt252, bool, u256) = self.last_taker_order_and_foc.read();
            if last_fill_taker_hash != taker_order_hash { assert(!is_foc || remaining == 0, 'FOK_PREVIOUS');}

            if taker_fill_info.filled_amount > 0 { assert(last_fill_taker_hash == taker_order_hash, 'IF_PARTIAL=>PREV_SAME');}


            assert(taker_order.fee.router_fee.taker_pbips == 0, 'TAKER_SAFE_REQUIRES_NO_ROUTER');
            
            return (taker_order, taker_order_hash, taker_fill_info);
        }

        fn settle_trade(ref self:ComponentState<TContractState>,maker_order:Order,taker_order:Order,amount_base:u256, amount_quote:u256, gas_px:u256) {
            self.rebalance_after_trade(maker_order, taker_order,amount_base,amount_quote);
            self.apply_maker_fee(maker_order,amount_base,amount_quote);
            self.emit(Trade{
                    maker:maker_order.maker,taker:taker_order.maker, ticker:maker_order.ticker,
                    amount_base:amount_base,amount_quote:amount_quote,is_sell_side:maker_order.flags.is_sell_side  });
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
        

        fn apply_taker_fee(
            ref self: ComponentState<TContractState>,
            taker_order:Order,
            gas_price:u256,
            base_amount:u256,
            quote_amount:u256
        ) {
            let mut balancer = self.get_balancer_mut();
            
            let taker_fee_token = if taker_order.flags.is_sell_side { let (b,q) = taker_order.ticker; q} else {let (b,q) = taker_order.ticker; b};
            let taker_fee_amount = get_feeable_qty(taker_order.fee.trade_fee, if taker_order.flags.is_sell_side { base_amount } else {quote_amount},false);
            assert(taker_order.fee.router_fee.taker_pbips == 0, 'TAKER_SAFE_REQUIRES_NO_ROUTER');
            if taker_fee_amount > 0 {
                balancer.internal_transfer(taker_order.maker, taker_order.fee.trade_fee.recipient, taker_fee_amount, taker_fee_token);
            }
            balancer.validate_and_apply_gas_fee_internal(taker_order.maker, taker_order.fee.gas_fee, gas_price);
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
}