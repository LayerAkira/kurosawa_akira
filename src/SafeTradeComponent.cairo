use kurosawa_akira::Order::{SignedOrder,Order, OrderTradeInfo, OrderFee, FixedFee,
            get_feeable_qty,get_limit_px, do_taker_price_checks, do_maker_checks, get_available_base_qty, TakerSelfTradePreventionMode};

#[starknet::interface]
trait ISafeTradeLogic<TContractState> {
    fn get_safe_trade_info(self: @TContractState, order_hash: felt252) -> OrderTradeInfo;
    fn get_safe_trades_info(self: @TContractState, order_hashes: Array<felt252>) -> Array<OrderTradeInfo>;
}

#[starknet::component]
mod safe_trade_component {
    use kurosawa_akira::ExchangeBalanceComponent::INewExchangeBalance;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component::InternalExchangeBalanceble;
    use core::{traits::TryInto,option::OptionTrait,array::ArrayTrait};
    use kurosawa_akira::FundsTraits::{PoseidonHash,PoseidonHashImpl};
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use kurosawa_akira::{NonceComponent::INonceLogic,SignerComponent::ISignerLogic};
    
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use starknet::{get_contract_address, ContractAddress, get_block_timestamp};
    use super::{do_taker_price_checks,do_maker_checks,get_available_base_qty, get_feeable_qty, get_limit_px, SignedOrder,Order, TakerSelfTradePreventionMode, OrderTradeInfo, OrderFee, FixedFee};
    use kurosawa_akira::utils::common::DisplayContractAddress;

    #[storage]
    struct Storage {
        orders_trade_info: LegacyMap::<felt252, OrderTradeInfo>
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Trade: Trade,
    }

    #[derive(Drop, starknet::Event)]
    struct Trade {
        maker:ContractAddress,
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
        fn get_safe_trades_info(self: @ComponentState<TContractState>, mut order_hashes: Array<felt252>) -> Array<OrderTradeInfo> {
            let mut res = ArrayTrait::new();
            loop {
                match order_hashes.pop_front(){
                    Option::Some(order_hash) => {res.append(self.get_safe_trade_info(order_hash))}, Option::None(_) => {break();}
                }
            };
            return res; 
        }
    }

     #[generate_trait]
    impl InternalSafeTradableImpl<TContractState, +HasComponent<TContractState>,+INonceLogic<TContractState>,
    +balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of InternalSafeTradable<TContractState> {

        // exposed only in contract user
        fn apply_trades(ref self: ComponentState<TContractState>, mut taker_orders:Array<(SignedOrder, bool)>, mut maker_orders:Array<SignedOrder>, mut iters:Array<(u8, bool)>, 
                    mut oracle_settled_qty:Array<u256>, gas_price:u256, version:u16, ) {
            let mut maker_order = *maker_orders.at(0).order;
            let mut maker_hash: felt252  = 0.try_into().unwrap();  
            let mut maker_fill_info = self.orders_trade_info.read(maker_hash);
            let (contract, balance) = (self.get_contract(), self.get_balancer_mut());
            
            let (_, use_prev_maker) = *iters.at(0);
            let mut first_iter = true;
            assert!(!use_prev_maker, "WRONG_FIRST_ITER");

            let fee_recipient = balance.fee_recipient.read();

            loop {
                match iters.pop_front(){
                    Option::Some((trades ,mut use_prev_maker)) => {
                        let (mut total_base, mut total_quote) = (0,0);
            
                        let (signed_taker_order, as_taker_completed) = taker_orders.pop_front().unwrap();
                        let (taker_order, taker_hash, mut taker_fill_info) =  self.part_validate_taker(signed_taker_order, trades); 
                        assert!(taker_order.fee.trade_fee.recipient == fee_recipient, "WRONG_TAKER_FEE_RECIPIENT: expected {} got {}", fee_recipient, taker_order.fee.trade_fee.recipient);
                        assert!(taker_order.version == version, "WRONG_TAKER_VERSION");
                        let mut cur = 0;

                        loop {
                            if cur == trades { break();}

                            if !use_prev_maker {
                                // update state for maker that gone (edge case if )
                                if first_iter {  first_iter = false; } else { self.orders_trade_info.write(maker_hash, maker_fill_info);}
                                //  pop new one do sign check  and update variables
                                let signed_order = maker_orders.pop_front().unwrap();
                                maker_order = signed_order.order;
                                maker_hash =  maker_order.get_poseidon_hash();
                                maker_fill_info = self.orders_trade_info.read(maker_hash);

                                do_maker_checks(maker_order, maker_fill_info, contract.get_nonce(maker_order.maker));
                                assert!(maker_order.fee.trade_fee.recipient == fee_recipient, "WRONG_MAKER_FEE_RECIPIENT: expected {} got {}", fee_recipient, maker_order.fee.trade_fee.recipient);
            
                                let (r, s) = signed_order.sign;
                                assert!(contract.check_sign(signed_order.order.maker, maker_hash, r, s), "WRONG_SIGN_MAKER: (maker_hash, r, s) : ({}, {} ,{})", maker_hash, r, s);

                            } else {
                                let remaining = get_available_base_qty(get_limit_px(maker_order, maker_fill_info), maker_order, maker_fill_info);
                                assert!(remaining > 0, "MAKER_ALREADY_PREVIOUSLY_FILLED");
                                use_prev_maker = false;
                            }
                            
                            if (taker_order.stp != TakerSelfTradePreventionMode::NONE) { // check stp mode, if not None reuqire prevention
                                assert!(contract.get_signer(maker_order.maker) != contract.get_signer(taker_order.maker), "STP_VIOLATED");
                            }
                            let settle_px = get_limit_px(maker_order, maker_fill_info);
                            let maker_qty = get_available_base_qty(settle_px, maker_order, maker_fill_info);
                            let taker_qty = do_taker_price_checks(taker_order, settle_px, taker_fill_info);
                            let mut settle_base_amount =  if maker_qty > taker_qty {taker_qty} else {maker_qty};
                            let oracle_settle_qty = oracle_settled_qty.pop_front().unwrap();
                            if oracle_settle_qty > 0 {
                                assert!(oracle_settle_qty <= settle_base_amount, "WRONG_ORACLE_SETTLE_QTY {} for {}", oracle_settle_qty, maker_hash);
                                settle_base_amount = oracle_settle_qty; 
                            }

                            assert!(taker_order.flags.is_sell_side != maker_order.flags.is_sell_side, "WRONG_SIDE");
                            assert!(taker_order.ticker == maker_order.ticker,"MISMATCH_TICKER");
                            assert!(taker_order.flags.to_safe_book == maker_order.flags.to_safe_book && taker_order.flags.to_safe_book, "WRONG_BOOK_DESTINATION");
                            assert!(taker_order.base_asset == maker_order.base_asset, "WRONG_ASSET_AMOUNT");
                            assert!(maker_order.version == version, "WRONG_MAKER_VERSION");
                            let settle_quote_amount = settle_px * settle_base_amount / maker_order.base_asset;
                            assert!(settle_quote_amount > 0, "0_QUOTE_AMOUNT");
                            
                            
                            
                            self.settle_trade(maker_order, taker_order, settle_base_amount, settle_quote_amount);
                            

                            total_base += settle_base_amount;
                            total_quote += settle_quote_amount;
                            
                            maker_fill_info.filled_amount += settle_base_amount;
                            maker_fill_info.filled_quote_amount += settle_quote_amount;
                            maker_fill_info.last_traded_px = settle_px;
                            
                            taker_fill_info.filled_amount += settle_base_amount;
                            taker_fill_info.filled_quote_amount += settle_quote_amount;
                            taker_fill_info.last_traded_px = settle_px; 
                            
                            cur += 1;
                        };
                        
                        taker_fill_info.num_trades_happened += trades;
                        taker_fill_info.as_taker_completed = as_taker_completed;

                        self.orders_trade_info.write(taker_hash, taker_fill_info);
                        
                        self.apply_taker_fee_and_gas(taker_order, total_base, total_quote, gas_price, trades);

                    },
                    Option::None(_) => {
                        assert!(taker_orders.len() == 0 && maker_orders.len() == 0 && iters.len() == 0, "MISMATCH");
                        // update state for last maker that gone
                        self.orders_trade_info.write(maker_hash, maker_fill_info);
                        break();
                    }
                }
            };
        }

        fn part_validate_taker(self: @ComponentState<TContractState>, taker_signed_order:SignedOrder, swaps:u8) -> (Order,felt252,OrderTradeInfo) {
            let (contract, taker_order,(r, s)) = (self.get_contract(), taker_signed_order.order, taker_signed_order.sign);
            let taker_order_hash = taker_order.get_poseidon_hash();
            let taker_fill_info = self.orders_trade_info.read(taker_order_hash);
            
            assert!(contract.check_sign(taker_order.maker, taker_order_hash, r, s), "WRONG_SIGN_TAKER: (taker_order_hash, r, s) = ({}, {}, {})", taker_order_hash, r, s);
            assert!(taker_order.number_of_swaps_allowed >= taker_fill_info.num_trades_happened + swaps, "HIT_SWAPS_ALLOWED");
            assert!(!taker_order.flags.post_only, "WRONG_TAKER_FLAG");
            assert!(taker_order.nonce >= contract.get_nonce(taker_order.maker),"OLD_TAKER_NONCE");
            // NASTY for now omit because headache if we lost info about order
            // let (last_fill_taker_hash, is_foc, remaining):(felt252, bool, u256) = self.last_taker_order_and_foc.read();
            // if last_fill_taker_hash != taker_order_hash { assert(!is_foc || remaining == 0, 'FOK_PREVIOUS');}
            // if taker_fill_info.filled_amount > 0 { assert(last_fill_taker_hash == taker_order_hash, 'IF_PARTIAL=>PREV_SAME');}

            assert!(taker_order.fee.router_fee.taker_pbips == 0, "TAKER_SAFE_REQUIRES_NO_ROUTER");
            // assert!(taker_order.quantity > taker_fill_info.filled_amount, "TAKER_ALREADY_FILLED"); #TODO we already checked that
            assert!(!taker_fill_info.as_taker_completed, "Taker order {} marked completed", taker_order_hash);
            assert!(get_block_timestamp() < taker_order.expire_at.into(), "Taker order expire {}", taker_order.expire_at);

            return (taker_order, taker_order_hash, taker_fill_info);
        }

        fn settle_trade(ref self:ComponentState<TContractState>,maker_order:Order,taker_order:Order,amount_base:u256, amount_quote:u256) {
            let mut balancer = self.get_balancer_mut();
            balancer.rebalance_after_trade(maker_order.maker, taker_order.maker,maker_order.ticker, amount_base, amount_quote,maker_order.flags.is_sell_side);
            balancer.apply_maker_fee(maker_order.maker, maker_order.fee.trade_fee, maker_order.flags.is_sell_side,
                                 maker_order.ticker, amount_base, amount_quote);
            assert!(maker_order.fee.router_fee.taker_pbips == 0, "MAKER_SAFE_REQUIRES_NO_ROUTER");
            
            self.emit(Trade{
                    maker:maker_order.maker, taker:taker_order.maker, ticker:maker_order.ticker,
                    amount_base, amount_quote, is_sell_side:maker_order.flags.is_sell_side });
        }   
        
        fn apply_taker_fee_and_gas(ref self: ComponentState<TContractState>, taker_order:Order, base_amount:u256, quote_amount:u256, gas_price:u256, trades:u8) {
            let mut balancer = self.get_balancer_mut();
            
            let taker_fee_token = if taker_order.flags.is_sell_side { let (b,q) = taker_order.ticker; q} else {let (b,q) = taker_order.ticker; b};
            let taker_fee_amount = get_feeable_qty(taker_order.fee.trade_fee, if taker_order.flags.is_sell_side { quote_amount } else {base_amount}, false);
            assert!(taker_order.fee.router_fee.taker_pbips == 0, "TAKER_SAFE_REQUIRES_NO_ROUTER");
            if taker_fee_amount > 0 {
                balancer.internal_transfer(taker_order.maker, taker_order.fee.trade_fee.recipient, taker_fee_amount, taker_fee_token);
            }

            balancer.validate_and_apply_gas_fee_internal(taker_order.maker, taker_order.fee.gas_fee, gas_price, trades);
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