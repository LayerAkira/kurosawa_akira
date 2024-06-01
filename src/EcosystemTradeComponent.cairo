use kurosawa_akira::Order::{SignedOrder,Order,get_gas_fee_and_coin, OrderTradeInfo, OrderFee, FixedFee,GasFee,
            get_feeable_qty,get_limit_px, do_taker_price_checks, do_maker_checks, get_available_base_qty, generic_taker_check,generic_common_check,TakerSelfTradePreventionMode};


#[starknet::interface]
trait IEcosystemTradeLogic<TContractState> {
    fn get_ecosystem_trade_info(self: @TContractState, order_hash: felt252) -> OrderTradeInfo;
    fn get_ecosystem_trades_info(self: @TContractState, order_hashes: Array<felt252>) -> Array<OrderTradeInfo>;
}

#[starknet::component]
mod ecosystem_trade_component {
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use kurosawa_akira::ExchangeBalanceComponent::INewExchangeBalance;
    use balance_component::{InternalExchangeBalancebleImpl, InternalExchangeBalanceble, ExchangeBalancebleImpl, FeeReward, Trade, Punish};
    
    use kurosawa_akira::{RouterComponent::IRouter};
    use kurosawa_akira::RouterComponent::router_component as router_component;
    use router_component::{InternalRoutable, RoutableImpl};    
    use core::{traits::TryInto,option::OptionTrait, array::ArrayTrait, traits::Destruct, traits::Into};
    use kurosawa_akira::FundsTraits::{check_sign};
    use kurosawa_akira::{NonceComponent::INonceLogic, SignerComponent::ISignerLogic};
    use starknet::{get_contract_address, ContractAddress, get_block_timestamp};
    use super::{do_taker_price_checks,do_maker_checks,get_available_base_qty, get_feeable_qty, get_limit_px, SignedOrder,Order, TakerSelfTradePreventionMode, OrderTradeInfo, OrderFee, FixedFee};
    use kurosawa_akira::utils::common::{DisplayContractAddress, min};

    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl, SNIP12MetadataImpl};


    #[storage]
    struct Storage {
        orders_trade_info: LegacyMap::<felt252, OrderTradeInfo>
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[embeddable_as(EcosystemTradable)]
    impl EcosystemTradableImpl<TContractState, +HasComponent<TContractState>,+INonceLogic<TContractState>,+balance_component::HasComponent<TContractState>,+router_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of super::IEcosystemTradeLogic<ComponentState<TContractState>> {
        fn get_ecosystem_trade_info(self: @ComponentState<TContractState>, order_hash: felt252) -> OrderTradeInfo {
            return self.orders_trade_info.read(order_hash);
        }
        fn get_ecosystem_trades_info(self: @ComponentState<TContractState>, mut order_hashes: Array<felt252>) -> Array<OrderTradeInfo> {
            let mut res = ArrayTrait::new();
            loop {
                match order_hashes.pop_front(){
                    Option::Some(order_hash) => {res.append(self.get_ecosystem_trade_info(order_hash))}, Option::None(_) => {break();}
                }
            };
            return res; 
        }
    }

     #[generate_trait]
    impl InternalEcosystemTradableImpl<TContractState, +HasComponent<TContractState>,+INonceLogic<TContractState>, +router_component::HasComponent<TContractState>,
    +balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of InternalEcosystemTradable<TContractState> {

        // exposed only in contract user apply ecosystem trades
        fn apply_ecosystem_trades(ref self: ComponentState<TContractState>, mut taker_orders:Array<(SignedOrder, bool)>, mut maker_orders:Array<SignedOrder>, mut iters:Array<(u16, bool)>,
                    mut oracle_settled_qty:Array<u256>, gas_price:u256,cur_gas_per_action:u32, version:u16) {
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
                    Option::Some((trades, mut use_prev_maker)) => {
                        let (mut total_base, mut total_quote) = (0,0);
            
                        let (signed_taker_order, as_taker_completed) = taker_orders.pop_front().unwrap();
                        let (taker_order, taker_hash, mut taker_fill_info) =  self.part_safe_validate_taker(signed_taker_order, trades, version, fee_recipient); 
                        let mut cur = 0;

                        loop {
                            if cur == trades { break();}

                            if !use_prev_maker {
                                // update state for maker that gone (edge case if )
                                if first_iter {  first_iter = false; } else { self.orders_trade_info.write(maker_hash, maker_fill_info);}
                                
                                let (new_maker_order,new_hash,new_fill_info) = self.do_internal_maker_checks(maker_orders.pop_front().unwrap(), fee_recipient);
                                maker_order = new_maker_order; maker_hash = new_hash; maker_fill_info = new_fill_info;
                                
                            } else {
                                let remaining = get_available_base_qty(get_limit_px(maker_order, maker_fill_info), maker_order.qty, maker_fill_info);
                                assert!(remaining > 0, "MAKER_ALREADY_PREVIOUSLY_FILLED");
                                use_prev_maker = false;
                            }
                            assert!(!taker_order.flags.external_funds && !maker_order.flags.external_funds, "WRONG_EXTERNAL_FLAGS");
                            
                            if (taker_order.constraints.stp != TakerSelfTradePreventionMode::NONE) { // check stp mode, if not None require prevention
                                assert!(contract.get_signer(maker_order.maker) != contract.get_signer(taker_order.maker), "STP_VIOLATED");
                            }
                            let (base, quote, px) = self.get_settled_amounts(maker_order, taker_order, maker_fill_info, taker_fill_info, oracle_settled_qty.pop_front().unwrap(), maker_hash);
                            self.settle_trade(maker_order, taker_order,base, quote);
                            total_base += base; total_quote += quote;
                            maker_fill_info.filled_base_amount += base; maker_fill_info.filled_quote_amount += quote; maker_fill_info.last_traded_px = px;
                            taker_fill_info.filled_base_amount += base; taker_fill_info.filled_quote_amount += quote; taker_fill_info.last_traded_px = px;
                        
                            cur += 1;
                        };
                        
                        taker_fill_info.num_trades_happened += trades; taker_fill_info.as_taker_completed = as_taker_completed;

                        self.orders_trade_info.write(taker_hash, taker_fill_info);
                        
                        self.apply_taker_fee_and_gas(taker_order, total_base, total_quote, gas_price, trades, cur_gas_per_action);

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

        fn apply_single_taker(ref self: ComponentState<TContractState>, signed_taker_order:SignedOrder, mut signed_maker_orders:Array<(SignedOrder,u256)>,
                    total_amount_matched:u256, gas_price:u256,  cur_gas_per_action:u32, as_taker_completed:bool, version:u16)  -> bool{
            
            let (exchange, trades): (ContractAddress, u16) = (get_contract_address(), signed_maker_orders.len().try_into().unwrap());
            let mut balancer = self.get_balancer_mut();
            let fee_recipient = balancer.fee_recipient.read();
            let (taker_order, taker_hash, mut taker_fill_info) =  if !signed_taker_order.order.flags.external_funds {
                self.part_safe_validate_taker(signed_taker_order, trades, version, fee_recipient)
            } else {
                let (o, hash, info, available) = self._do_part_external_taker_validate(signed_taker_order, trades, version, fee_recipient);
                // prevent exchange trigger reimburse on purpose else we can send 0 and it will trigger failure on checks and trigger router punishment
                //  we need this oracle because we might dont know beforehand how much taker will spent because px is protection price
                assert!(total_amount_matched <= available, "WRONG_AMOUNT_MATCHED_ORACLE got {} should be less {}", total_amount_matched, available);
                (o, hash, info)
            };
                                
            let mut expected_amount_spend = if taker_order.flags.external_funds  {
                // HOW to deal with PPL that create AA that force exception in implementation?
                if !check_sign(taker_order.maker, taker_hash, signed_taker_order.sign) {0}
                else {
                    if !self._prepare_router_taker(taker_order, total_amount_matched, exchange, trades, gas_price, cur_gas_per_action) {0} else {total_amount_matched}
                }
            } else {total_amount_matched};

            let contract = self.get_contract();
            let failed = expected_amount_spend == 0;
            let (mut accum_base, mut accum_quote) = (0,0);
            loop {
                match signed_maker_orders.pop_front(){
                    Option::Some((signed_maker_order, oracle_settle_qty)) => {
                        let maker_order = signed_maker_order.order;
                        // even if external taker fails we must validate makers are correct ones
                        let (maker_order, maker_hash, mut maker_fill_info) = self.do_internal_maker_checks(signed_maker_order, fee_recipient);
                        let (amount_base, amount_quote, settle_px) = self.get_settled_amounts(maker_order, taker_order, maker_fill_info, taker_fill_info,oracle_settle_qty, maker_hash);
                        
                        if (!taker_order.flags.external_funds && taker_order.constraints.stp != TakerSelfTradePreventionMode::NONE) {
                            assert!(contract.get_signer(maker_order.maker) != contract.get_signer(taker_order.maker), "STP_VIOLATED");
                        }
                        
                        if taker_order.flags.external_funds && failed {
                            self.punish_router_simple(taker_order.fee.gas_fee, taker_order.fee.router_fee.recipient, 
                                        signed_maker_order.order.maker, taker_order.maker, gas_price, taker_hash, maker_hash);

                            balancer.emit(Trade{
                                router_maker:maker_order.fee.router_fee.recipient, router_taker:taker_order.fee.router_fee.recipient,
                                maker:maker_order.maker, taker:taker_order.maker, ticker:maker_order.ticker, is_failed:true, 
                                is_ecosystem_book:maker_order.flags.to_ecosystem_book, amount_base, amount_quote, is_sell_side:maker_order.flags.is_sell_side });
                            continue;
                        }

                        self.settle_trade(maker_order, taker_order, amount_base, amount_quote);

                        maker_fill_info.filled_base_amount += amount_base; maker_fill_info.filled_quote_amount += amount_quote; maker_fill_info.last_traded_px = settle_px;
                        taker_fill_info.filled_base_amount += amount_base; taker_fill_info.filled_quote_amount += amount_quote; taker_fill_info.last_traded_px = settle_px;
                        self.orders_trade_info.write(maker_hash, maker_fill_info);
                        accum_base += amount_base; accum_quote += amount_quote;
                        
                    },
                    Option::None(_) => { 
                        if taker_order.flags.external_funds && failed {// invalidate order
                            taker_fill_info.filled_base_amount = taker_order.qty.base_qty;
                            taker_fill_info.filled_quote_amount = taker_order.qty.quote_qty;
                        }
                        taker_fill_info.as_taker_completed = as_taker_completed;
                        taker_fill_info.num_trades_happened += trades;
                        self.orders_trade_info.write(taker_hash, taker_fill_info);

                        break();
                    }
                }
            };

            if taker_order.flags.external_funds && failed { return false;}
            if taker_order.flags.external_funds {
                let (taker_received, unspent) = if taker_order.flags.is_sell_side {
                    assert(expected_amount_spend - accum_base  >= 0, 'FINALIZE_BASE_OVERFLOW');                    
                    (accum_quote, expected_amount_spend - accum_base)
                } else {
                    assert(expected_amount_spend - accum_quote  >= 0, 'FINALIZE_BASE_OVERFLOW');                    
                    (accum_base, expected_amount_spend - accum_quote)
                };
                // do the reward and pay for the gas, we accumulate all and consume at once, avoiding repetitive actions
                self.finalize_router_taker(taker_order, taker_hash, taker_received, unspent, exchange, gas_price, trades, cur_gas_per_action);  
            } else  {
                self.apply_taker_fee_and_gas(taker_order, accum_base, accum_quote, gas_price, trades, cur_gas_per_action);    
            }

            
            return true;     
        }


        fn do_internal_maker_checks(self: @ComponentState<TContractState>, signed_order:SignedOrder, fee_recipient:ContractAddress) -> (Order,felt252, OrderTradeInfo) {
            let (contract, order, (r, s)) = (self.get_contract(), signed_order.order, signed_order.sign);
            let maker_hash =  order.get_message_hash(order.maker);
            let maker_fill_info = self.orders_trade_info.read(maker_hash);
            do_maker_checks(order, maker_fill_info, contract.get_nonce(order.maker), fee_recipient);            
            assert!(contract.check_sign(signed_order.order.maker, maker_hash, r, s), "WRONG_SIGN_MAKER: (maker_hash, r, s) : ({}, {} ,{})", maker_hash, r, s);
            return (order, maker_hash, maker_fill_info);
        }


        fn part_safe_validate_taker(self: @ComponentState<TContractState>, taker_signed_order:SignedOrder, swaps:u16, version:u16, fee_recipient:ContractAddress) -> (Order,felt252,OrderTradeInfo) {
            let (contract, taker_order,(r, s)) = (self.get_contract(), taker_signed_order.order, taker_signed_order.sign);
            let taker_order_hash = taker_order.get_message_hash(taker_order.maker);
            let taker_fill_info = self.orders_trade_info.read(taker_order_hash);
            
            assert(!taker_order.flags.external_funds, 'ECOSYSTEM_TAKER_NOT_EXTERNAL');
            assert!(contract.check_sign(taker_order.maker, taker_order_hash, r, s), "WRONG_SIGN_TAKER: (taker_order_hash, r, s) = ({}, {}, {})", taker_order_hash, r, s);
            super::generic_taker_check(taker_order, taker_fill_info, contract.get_nonce(taker_order.maker), swaps, taker_order_hash, version, fee_recipient);
            return (taker_order, taker_order_hash, taker_fill_info);
        }

        fn settle_trade(ref self:ComponentState<TContractState>, maker_order:Order, taker_order:Order, settle_base_amount:u256, settle_quote_amount:u256 ) {
            // Tfer amount between account on settled trades and apply maker fees both trade and router fee if specified
            let mut balancer = self.get_balancer_mut();
            balancer.rebalance_after_trade(maker_order.maker, taker_order.maker, maker_order.ticker, settle_base_amount, settle_quote_amount, maker_order.flags.is_sell_side);
            self.apply_fixed_fees(maker_order, settle_base_amount, settle_quote_amount, true);
            balancer.emit(Trade{
                router_maker:maker_order.fee.router_fee.recipient, router_taker:taker_order.fee.router_fee.recipient,
                maker:maker_order.maker, taker:taker_order.maker, ticker:maker_order.ticker, is_failed:false, 
                is_ecosystem_book:maker_order.flags.to_ecosystem_book, amount_base:settle_base_amount, amount_quote:settle_quote_amount, is_sell_side:maker_order.flags.is_sell_side });
        }

        fn get_settled_amounts(self:@ComponentState<TContractState>, maker_order:Order,taker_order:Order, maker_fill_info:OrderTradeInfo, taker_fill_info:OrderTradeInfo, 
                        oracle_settle_qty:u256, maker_hash:felt252) -> (u256, u256, u256) {
            let balancer = self.get_balancer();
            
            let settle_px = get_limit_px(maker_order, maker_fill_info);
            let maker_qty = get_available_base_qty(settle_px, maker_order.qty, maker_fill_info);
            let taker_qty = do_taker_price_checks(taker_order, settle_px, taker_fill_info);
            let mut settle_base_amount = if maker_qty > taker_qty {taker_qty} else {maker_qty};
            if oracle_settle_qty > 0 {
                assert!(oracle_settle_qty <= settle_base_amount, "WRONG_ORACLE_SETTLE_QTY {} for {}", oracle_settle_qty, maker_hash);
                settle_base_amount = oracle_settle_qty; 
            }
            super::generic_common_check(maker_order, taker_order);
            let settle_quote_amount = settle_px * settle_base_amount / maker_order.qty.base_asset;
            assert!(settle_quote_amount > 0, "0_QUOTE_AMOUNT");
            return (settle_base_amount, settle_quote_amount, settle_px);

        }   
        
        fn apply_taker_fee_and_gas(ref self: ComponentState<TContractState>, taker_order:Order, base_amount:u256, quote_amount:u256, gas_price:u256, trades:u16, cur_gas_per_action:u32) -> (ContractAddress, u256, u256) {
            let mut balancer = self.get_balancer_mut();
            let (fee_token, fee_amount, exchange_fee) = self.apply_fixed_fees(taker_order,base_amount, quote_amount, false);
            balancer.validate_and_apply_gas_fee_internal(taker_order.maker, taker_order.fee.gas_fee, gas_price, trades, cur_gas_per_action);
            return (fee_token, fee_amount, exchange_fee);
        }

        fn apply_fixed_fees(ref self: ComponentState<TContractState>,order:Order,base_amount:u256, quote_amount:u256,is_maker:bool) -> (ContractAddress,u256, u256) {
            let mut balancer = self.get_balancer_mut();
            let (_, exchange_fee) =  balancer.apply_fixed_fee(order.maker, order.fee.trade_fee, order.flags.is_sell_side, order.ticker, base_amount, quote_amount, is_maker);
            let (fee_token, fee_amount) = balancer.apply_fixed_fee(order.maker, order.fee.router_fee, order.flags.is_sell_side, order.ticker, base_amount, quote_amount, is_maker);

            if fee_amount > 0 { 
                let mut router = self.get_router_mut();
                // explicitly separate routers balance from balance on exchange, separate entities
                router.mint(order.fee.router_fee.recipient, fee_token, fee_amount);
                balancer.burn(order.fee.router_fee.recipient, fee_amount, fee_token);     
                balancer.emit(FeeReward{ recipient:order.fee.router_fee.recipient, token:fee_token, amount:fee_amount});
            }
            return (fee_token, fee_amount, exchange_fee);
        }

        fn _do_part_external_taker_validate(self:@ComponentState<TContractState>, signed_taker_order:SignedOrder, swaps:u16, version: u16, fee_recipient:ContractAddress) -> (Order,felt252,OrderTradeInfo, u256) {
            //Returns max user can actually spend
            let (router, taker_order, contract) = (self.get_router(), signed_taker_order.order,self.get_contract());
            let taker_hash = taker_order.get_message_hash(taker_order.maker);
            let taker_fill_info = self.orders_trade_info.read(taker_hash);
            
            //Validate router, job of exchange because of this assert
            assert!(router.validate_router(taker_hash, signed_taker_order.router_sign, taker_order.constraints.router_signer, taker_order.fee.router_fee.recipient), "WRONG_ROUTER_SIGN");
            // nonce here so router cant on purpose send old orders of user
            super::generic_taker_check(taker_order, taker_fill_info, taker_order.constraints.nonce, swaps, taker_hash, version, fee_recipient);
            assert!(taker_order.flags.is_market_order, "WRONG_MARKET_TYPE_EXTERNAL"); // external ones cant become passive orders
            let remaining_taker_amount =  self._infer_upper_bound_required(taker_order, taker_fill_info);
            assert!(remaining_taker_amount > 0, "WRONG_TAKER_AMOUNT");
            return (taker_order, taker_hash, taker_fill_info, remaining_taker_amount);
        }

        fn _infer_upper_bound_required(self:@ComponentState<TContractState>, taker_order:Order, taker_fill_info:OrderTradeInfo) ->u256 {
            // Gives approximation how much user must have tokens that he is willing to spend
            if taker_order.flags.is_sell_side { // sell of base asset
                return get_available_base_qty(taker_order.price, taker_order.qty, taker_fill_info);
            } else { // sell of quote asset
                
                let by_quote_asset = if taker_order.qty.quote_qty > 0 {
                    assert!(taker_order.qty.quote_qty >= taker_fill_info.filled_quote_amount,  "Order already filled by quote quote {} filled {}",
                                taker_order.qty.quote_qty, taker_fill_info.filled_quote_amount);
                    taker_order.qty.quote_qty - taker_fill_info.filled_quote_amount} else {0};

                let by_base_asset = if taker_order.qty.base_qty > 0 {
                    assert!(taker_order.qty.base_qty >= taker_fill_info.filled_base_amount,  "Order already filled by base base {} filled {}",
                                taker_order.qty.base_qty, taker_fill_info.filled_base_amount);
                    taker_order.price * (taker_order.qty.base_qty - taker_fill_info.filled_base_amount) / taker_order.qty.base_asset} else {0};
                
                if taker_order.qty.base_qty == 0 {return by_quote_asset;}
                if taker_order.qty.quote_qty == 0 { return by_base_asset;}
                return min(by_quote_asset, by_base_asset);
            }     
        }

        fn _prepare_router_taker(ref self:ComponentState<TContractState>, taker_order:Order, mut out_amount:u256, exchange:ContractAddress, swaps:u16,
                            gas_price:u256, cur_gas_per_action:u32) -> bool {
            // Prepare taker context for the trade when it have external funds mode
            // 1) Checks if user granted necessary permissions and have enough balance, and nonce of order is correct
            // 2) Tfer necessary amount for the trade and mint tokens on exchange for the user
            // 3) returns total out amount wrt to gas if same token
            // In case of failure returns 0 signalizing that issue due router's bad job
            let (base, quote) = (taker_order.ticker);
            let mut balancer = self.get_balancer_mut();
            let contract = self.get_contract();

            if taker_order.constraints.nonce < contract.get_nonce(taker_order.maker) { return false;}
            

            let (erc20_base, erc20_quote) = (IERC20Dispatcher{contract_address:base}, IERC20Dispatcher{contract_address:quote});
            let (spent_gas, gas_token) = super::get_gas_fee_and_coin(taker_order.fee.gas_fee, gas_price, balancer.wrapped_native_token.read(), cur_gas_per_action);
            let mut spent_gas = spent_gas * swaps.into();
            let trade_spend_token =  if taker_order.flags.is_sell_side {base} else {quote};
            if trade_spend_token == gas_token  {
                out_amount += spent_gas;
                spent_gas = 0;
            } 
            if !self.can_tranfer(exchange, trade_spend_token, taker_order.maker, out_amount) {return false;}
            if !self.can_tranfer(exchange, gas_token, taker_order.maker, spent_gas) {return false;}
            self.trasfer_in(exchange, trade_spend_token, taker_order.maker, out_amount);
            self.trasfer_in(exchange, gas_token, taker_order.maker, spent_gas);

            return true;
        }

        fn finalize_router_taker(ref self:ComponentState<TContractState>, taker_order:Order, taker_hash:felt252, received_amount:u256, unspent_amount:u256, exchange:ContractAddress, gas_price:u256, trades:u16, cur_gas_per_action:u32) {
            // Finalize router taker
            // 1) pay for gas, trade, router fee
            // 2) transfer user erc20 tokens that he received + unspent amount of tokens he was selling
            let (b, q) = if taker_order.flags.is_sell_side { (0, received_amount) } else { (received_amount, 0) };
            let spending_token = if taker_order.flags.is_sell_side {let (b,q) = taker_order.ticker; b} else {let (b,q) = taker_order.ticker;q};
            let mut balancer = self.get_balancer_mut();
            
            let (fee_token, router_fee_amount, exchange_fee_amount) =  self.apply_taker_fee_and_gas(taker_order, b, q, gas_price, trades, cur_gas_per_action);
            
            // tfer trade result
            self.trasfer_back(exchange, fee_token, taker_order.maker, received_amount - router_fee_amount - exchange_fee_amount);
            self.trasfer_back(exchange, spending_token, taker_order.maker, unspent_amount); // tfer unspent amount
        }
      
        fn punish_router_simple(ref self: ComponentState<TContractState>, gas_fee:super::GasFee,router_addr:ContractAddress, 
                    maker:ContractAddress, taker:ContractAddress, gas_px:u256,taker_hash:felt252,maker_hash:felt252) {
            let (mut balancer, mut router) = (self.get_balancer_mut(), self.get_router_mut());
            let native_base_token = balancer.get_wrapped_native_token();
            let charged_fee = gas_fee.gas_per_action.into() * gas_px * router.get_punishment_factor_bips().into() / 10000;
            if charged_fee == 0 {return;}
            router.burn(router_addr, native_base_token, 2 * charged_fee); // punish
            balancer.mint(balancer.fee_recipient.read(), charged_fee, native_base_token); // reimburse
            balancer.mint(maker, charged_fee, native_base_token); // reimburse
            balancer.emit(Punish{router:router_addr, taker_hash, maker_hash, amount: 2 * charged_fee});
        }

        fn trasfer_back(ref self:ComponentState<TContractState>, exchange:ContractAddress, token:ContractAddress, maker:ContractAddress, amount:u256) {
            if amount == 0 {return;}
            let mut balancer = self.get_balancer_mut();
            let erc = IERC20Dispatcher {contract_address:token};

            let balance = erc.balanceOf(exchange);
            erc.transfer(maker, amount);
            balancer.burn(maker, amount, token);
            assert!(balance - erc.balanceOf(exchange) <= amount, "OUT_TFER_ERROR {} {} {}", token, maker, amount); // ensure token contract not drains any extra
        }

        fn trasfer_in(ref self:ComponentState<TContractState>, exchange:ContractAddress, token:ContractAddress, maker:ContractAddress, amount:u256) {
            if amount == 0 {return;}
            let mut balancer = self.get_balancer_mut();
            let erc = IERC20Dispatcher {contract_address:token};
            let balance = erc.balanceOf(exchange);

            erc.transferFrom(maker, exchange, amount);
            balancer.mint(maker, amount, token);
            assert!(erc.balanceOf(exchange) - balance >= amount, "IN_TFER_ERROR {} {} {}", token, maker, amount); // ensure token contract not drains any extra
        }
        fn can_tranfer(self:@ComponentState<TContractState>, exchange:ContractAddress, token:ContractAddress, maker:ContractAddress, amount:u256) -> bool {
            if amount == 0 {return true;}
            let erc = IERC20Dispatcher {contract_address:token};
            if erc.allowance(maker, exchange) < amount { return false;}
            if erc.balanceOf(maker) < amount { return false;}
            return true;
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
