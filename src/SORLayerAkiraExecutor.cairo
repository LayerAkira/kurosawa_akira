use kurosawa_akira::Order::{SignedOrder,Order,SimpleOrder,SimpleOrderImpl,OrderImpl,GasContext,get_gas_fee_and_coin, OrderTradeInfo, OrderFee, FixedFee,GasFee, OrderFlags, Constraints, Quantity,
            get_feeable_qty,get_limit_px, do_taker_price_checks, do_maker_checks, get_available_base_qty, generic_taker_check,generic_common_check,TakerSelfTradePreventionMode};
use starknet::{ContractAddress};
use core::option::Option;
    
#[starknet::interface]
trait ISORTradeLogic<TContractState> {}


// internal structure used for storing client sored order, up to 3 orders
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SOR {
    lead:Order, // lead order which defines the begining of complex route
    order0:Option<SimpleOrder>,
    order1:Option<SimpleOrder>,
    last_order: SimpleOrder, // last order in path
	router_signature_lead:(felt252,felt252),
	allow_nonatomic_processing:bool, // does user allow for his sor to be processed non atomically in separate txs
	trade_fee: FixedFee, // fee incur only on lead or last order, intermediary no charges
    router_fee:FixedFee, // fee incur only on lead or last order, intermediary no charges
    integrator_fee:FixedFee,
    
    apply_gas_in_first_trade: bool, // gas charged in beg or end leg
    path_len:u8, // len of path excluding lead order
    trades_max:u16, //
    min_receive_amount:u256, // for end leg
    max_spend_amount: u256, // for begining leg
    last_qty:Quantity, // forecasted qty by the user for last order
    apply_to_receipt_amount:bool,
    
}
#[derive(Copy, Drop, Serde)]
struct SORDetails { // details supplied with sor sored orders
    lead_qty:Quantity, // forecasted qty by the user
    last_qty:Quantity, // forecasted qty by the user, ignored in case of exact sell
    trade_fee:FixedFee, // same as in Order
    router_fee:FixedFee,// same as in Order
    integrator_fee:FixedFee,
    apply_to_receipt_amount:bool,
    gas_fee: GasFee,// same as in Order
    created_at:u32, // same as in Order
    source:felt252, // same as in Order
    allow_nonatomic:bool, // should it be performed atomically or can be split; for large orders might work only splitting due calldata limit sz
    to_ecosystem_book:bool, // same as in Order
    duration_valid:u32,
    nonce:u32, // same as in Order
    external_funds:bool, // same as in Order
    router_signer:ContractAddress, // same as in Order
    salt:felt252, // same as in Order
    sign_scheme:felt252, // same as in Order
    number_of_swaps_allowed: u16, 
    min_receive_amount:u256, // for end leg
    max_spend_amount: u256 // for begining leg
    // target_receive: 
}

#[starknet::contract]
mod SORLayerAkiraExecutor {
    use starknet::{get_contract_address, ContractAddress, get_caller_address, get_tx_info, get_block_timestamp};
    use super::{SignedOrder, Order,GasContext, SimpleOrderImpl,OrderImpl,};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl, SNIP12MetadataImpl};
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcherTrait, ILayerAkiraCoreDispatcher};
    use kurosawa_akira::LayerAkiraBaseExecutor::{ILayerAkiraBaseExecutorDispatcherTrait, ILayerAkiraBaseExecutorDispatcher};

    use core::option::Option;
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}


    #[storage]
    struct Storage {
        base_executor_address:ContractAddress,
        atomic_taker_info:(felt252, (felt252, felt252)), // hash lock, router sign
        scheduled_taker_order: Order,
        order_hash_to_sor:starknet::storage::Map::<felt252, super::SOR>,
        sor_to_ptr:starknet::storage::Map::<felt252, (u8,bool)>, // index and is failed sor
        atomic_sor:super::SOR,        
    }

    #[constructor]
    fn constructor(ref self: ContractState, base_executor_address:ContractAddress) {
        self.base_executor_address.write(base_executor_address);   
    }

    #[external(v0)]
    fn placeTakerOrder(ref self: ContractState, order: Order, router_sign: (felt252,felt252)) {
        let tx_info = get_tx_info().unbox();
        let mut base_trade = ILayerAkiraBaseExecutorDispatcher{contract_address:self.base_executor_address.read()};
        if (!base_trade.is_wlsted_invoker(tx_info.account_contract_address)) {return;}; // shallow termination for client// argent simulation
        _placeTakerOrder(ref self, order, router_sign);
    }

    #[external(v0)]
    fn fullfillTakerOrder(ref self: ContractState, mut maker_orders:Array<(SignedOrder,u256)>,
                    total_amount_matched:u256, gas_steps:u32, gas_price:u256) {
        assert(ILayerAkiraBaseExecutorDispatcher{contract_address:self.base_executor_address.read()}.is_wlsted_invoker(get_caller_address()),'not wlisted');
        _fullfillTakerOrder(ref self, maker_orders, total_amount_matched, gas_steps, gas_price);
    }

    #[external(v0)]
    fn placeSORTakerOrder(ref self: ContractState, orchestrate_order: super::SimpleOrder, path:Array<super::SimpleOrder>, router_signature:(felt252, felt252), details: super::SORDetails) {
        let tx_info = get_tx_info().unbox();
        let mut base_trade = ILayerAkiraBaseExecutorDispatcher{contract_address:self.base_executor_address.read()};
        if (!base_trade.is_wlsted_invoker(tx_info.account_contract_address)) {return;}; // shallow termination for client// argent simulation
        _placeSOROrder(ref self, orchestrate_order, path, router_signature, details);
    }

    #[external(v0)]
    fn fulfillSORAtomic(ref self: ContractState, makers_orders:Array<(SignedOrder,u256)>,
                        total_amount_matched_and_len:Array<(u256, u8)>, gas_steps:u32, gas_price:u256, sor_id:felt252) {
        assert(ILayerAkiraBaseExecutorDispatcher{contract_address:self.base_executor_address.read()}.is_wlsted_invoker(get_caller_address()),'not wlisted');
        _fulfillSORAtomic(ref self, makers_orders, total_amount_matched_and_len, GasContext{cur_gas_per_action:gas_steps, gas_price}, sor_id);           
    }

    fn _placeTakerOrder(ref self: ContractState, order: Order, router_sign: (felt252,felt252)) {
        // SNIP-9 place of taker order onchain, rolluper calls account which calls placeTakerOrder
        //  Params:
        //      order: taker order to be filled
        //      router_sign: signature of order if any by router that guarantee correctness of the order   
        assert(order.maker == get_caller_address(), 'Maker must be caller');
        acquireLock(ref self, router_sign);
        self.scheduled_taker_order.write(order);
        }
    
    fn _fullfillTakerOrder(ref self: ContractState, mut maker_orders:Array<(SignedOrder, u256)>,
                        total_amount_matched:u256, gas_steps:u32, gas_price:u256) {
            // SNIP-9 execution of taker order onchain
            // rollup MULTICALL: [approve, ..., approve, placeTakerOrder, fullfillTakerOrder]
            //  Params:
            //      maker_orders: array of tuples -- (maker order, base amount matched) against which taker was matched
            //      total_amount_matched: total amount spent by taker in spending token of the trade
            //      gas_steps: actual amount steps to settle 1 trade
            //      gas_price: real gas price per 1 gas
            
            let mut base_trade = ILayerAkiraBaseExecutorDispatcher{contract_address:self.base_executor_address.read()};

            let (order, allow_charge_gas_on_receipt, as_taker_filled) = (self.scheduled_taker_order.read(), true, true); 
            let (skip_taker_validation, gas_trades, tfer_taker_recieve_back) = (true, maker_orders.len().try_into().unwrap(), order.flags.external_funds);
            let (_, router_signature) = self.atomic_taker_info.read();
            
            let (succ, taker_hash) = base_trade.apply_single_taker(SignedOrder{ order, sign: array![].span(), router_sign:router_signature}, maker_orders.span(), 
                total_amount_matched, gas_price, gas_steps, as_taker_filled, skip_taker_validation, gas_trades, tfer_taker_recieve_back, allow_charge_gas_on_receipt);
            if succ {assert_slippage(@self, taker_hash, 0, order.constraints.min_receive_amount);}

            releaseLock(ref self);
        }


		fn _placeSOROrder(ref self: ContractState, orchestrate_order:super::SimpleOrder, 
                path:Array<super::SimpleOrder>, router_signature:(felt252, felt252), details:super::SORDetails){
            // SNIP-9 place of sor order (for example, client wants to sell SHIBA for WstETH) and exchange have tickers SHIBA/STRK, ETH/STRK and WstETH/ETH   
            //  Params:
            //      orchestrate_order:  lead order that defined whole sor
            //      path: complex direct straight path that starts from result of orchestrate_order token
            //      router_signature: signature of order if any by router that guarantee correctness of the order 
            //      details: order details supplied to build full taker order inplace from orchestrate_order
            //  Constraints:
            //      - Path is limited to 5 tickers (edges) -- synthethic order mathcing
            //      - First order is defined by external_funds parameter; remaining are in safe determinstic ctx (external_funds==False)
            //      - First order incur router & trade fee, and 0 fees for rest iff fixed fee apply_to_receipt == False
            //      - Last order incur router & trade fee, and 0 fees for rest iff fixed fee apply_to_receipt == True
            //      - Gas for all trades paid only at first trade iff payment token  == spending token or payment token (1)  != last trade receive token (2)
            //      - Gas for all trades paid only at last trade  iff payment token  == last trade receive token
            //      - Gas must be tferred beforehand iff (1) & (2) even if (2) is in path sequence

		    let sz = path.len();
            assert(sz != 0, 'use non bulk'); assert(sz <= 5, 'path is too long');
            
            // no cycles checked in buildSOR
            let new_sor = buildSOR(@self, orchestrate_order, path, router_signature, details);
            
            if (details.allow_nonatomic) {
                let key = new_sor.lead.get_message_hash(new_sor.lead.maker); 
                let sor = self.order_hash_to_sor.read(key);
                assert(sor.lead.maker.try_into().unwrap() == 0, 'sor already existed');
                self.order_hash_to_sor.write(key, new_sor);
            } else {
                 acquireLock(ref self, router_signature); 
                 self.atomic_sor.write(new_sor);
            }
        }

        fn _fulfillSORAtomic(ref self: ContractState, makers_orders:Array<(SignedOrder,u256)>,
                        total_amount_matched_and_len:Array<(u256, u8)>, gas_ctx:GasContext, sor_id:felt252) {
            // SNIP-9 call
            // Allows to fulfill sored client orders atomically within 1 tx
            // Multicall: [approve,..., approve, placeSOROrder, fulfillSORAtomic]
            //  Params:
            //      makers_orders: 1dim array of all maker orders for whole sor (2dim need to avoid use copy)
            //      total_amount_matched_and_len: tuple of <amount sold by client for an order, total trades happend with that order>
            //      gas_steps: actual amount steps to settle 1 trade
            //      gas_price: real gas price per 1 gas
            //      sor_id: 0 if taker order is atomic_only else lead_order hash (exchange attempt to fill non atomic sor orders atomically) 

            // if client set allow non atomic -> exchange can still use fulfillSORAtomic if all trades can fit into one 1 rollup
            let total_trades:u16 = makers_orders.len().try_into().unwrap();
            let sor = if sor_id != 0.try_into().unwrap() {
                let sor = self.order_hash_to_sor.read(sor_id);
                let (head, _) = self.sor_to_ptr.read(sor_id);
                assert(head == 0, 'sor already processed');
                sor
            } else {self.atomic_sor.read()};
            assert(sor.lead.maker != 0x0.try_into().unwrap(), 'sor not initialized');
            assert(total_trades <= sor.trades_max, 'Failed max trades');

            let ((first, last), (total_amount_matched, swaps)) = ((sor.lead, sor.last_order), *total_amount_matched_and_len.at(0));
            
            
            let span_amount_matched = total_amount_matched_and_len.span().slice(1, total_amount_matched_and_len.len() - 1); 
            let (makers_span, fee_recipient) = (makers_orders.span(), first.fee.trade_fee.recipient);
            
            // charge for gas at very first or
            // responsibility of layer akira backend if on last order 
            // if some intermediary force to check if have enough; gas charged from the begining, avoid use receive side  
            let (gas_trades, last_trades) = if sor.apply_gas_in_first_trade {(total_trades,0)} else {(0,total_trades)};
            let (skip_taker_validation, allow_charge_gas_on_receipt, tfer_back_received) = (true, false, false);
            let mut base_trade = ILayerAkiraBaseExecutorDispatcher{contract_address:self.base_executor_address.read()};

            
            let (succ, lead_taker_hash) = base_trade.apply_single_taker(
                        SignedOrder{order:first, sign: array![].span(), router_sign:sor.router_signature_lead},
                        makers_span.slice(0, swaps.try_into().unwrap()), total_amount_matched, gas_ctx.gas_price, gas_ctx.cur_gas_per_action, true, 
                            skip_taker_validation, gas_trades, tfer_back_received, allow_charge_gas_on_receipt);
            if succ {assert_slippage(@self, sor_id, sor.max_spend_amount, 0);}


            let (zero_trade_fee, zero_router_fee, zero_integrator_fee) =  getTradeAndRouterFees(@self, sor, false);
            // apply all the orders
            let (mut ptr, mut offset, tfer_taker_recieve_back) = (0, swaps.try_into().unwrap(), false);
            let (ptr1, offset1, __) = apply(ref self, first, sor.order0, zero_trade_fee, zero_router_fee, zero_integrator_fee, ptr, offset, makers_span, span_amount_matched, succ, 0, fee_recipient, tfer_taker_recieve_back, lead_taker_hash, Option::None,sor.apply_to_receipt_amount, gas_ctx);
            ptr = ptr1; offset = offset1;
            let (ptr1, offset1, __) = apply(ref self, first, sor.order1, zero_trade_fee, zero_router_fee, zero_integrator_fee, ptr, offset, makers_span, span_amount_matched, succ, 0, fee_recipient, tfer_taker_recieve_back, lead_taker_hash, Option::None,sor.apply_to_receipt_amount, gas_ctx);
            ptr = ptr1; offset = offset1;
            
            let tfer_back_received =  first.flags.external_funds;
            let (last_trade_fee, last_router_fee,last_integrator_fee) = if (sor.apply_to_receipt_amount) {(sor.trade_fee, sor.router_fee, sor.integrator_fee)} else {(zero_trade_fee, zero_router_fee, zero_integrator_fee)};
            
            // if exact sell then we need fullfill only otherwise we were doing exact buy amount
            let last_order_qty = if sor.max_spend_amount != 0 {Option::Some(sor.last_qty)} else {Option::None};
            let (ptr1, offset1, taker_hash) = apply(ref self, first, Option::Some(last), last_trade_fee, last_router_fee, last_integrator_fee,
                    ptr, offset, makers_span, span_amount_matched, succ, last_trades, fee_recipient, tfer_back_received, lead_taker_hash, last_order_qty, sor.apply_to_receipt_amount, gas_ctx);
            ptr = ptr1; offset = offset1;
            if succ {assert_slippage(@self, taker_hash, 0, sor.min_receive_amount);}

            assert(offset == total_trades.into(), 'Mismatch orders count');
            if sor_id != 0.try_into().unwrap() {
                self.sor_to_ptr.write(sor_id, (sor.path_len + 1, !succ)); 
            }  else {
                releaseLock(ref self);
            }
            // if exact sell last order fullfill only and qty built from previous
            // if exact buy  but first must be  < -- todo mb not releavnt
            
        }


    fn acquireLock(ref self:ContractState, router_sign:(felt252,felt252)) {
        //lock defined by tx_hash of ongoing tx
        let (hash_lock, _) = self.atomic_taker_info.read();
        assert(hash_lock == 0, 'Lock already acquired');       
        let tx_info = get_tx_info().unbox();
        self.atomic_taker_info.write((tx_info.transaction_hash, router_sign));
    }

    fn releaseLock(ref self:ContractState) {
        let (hash_lock, _) = self.atomic_taker_info.read();            
        let tx_info = get_tx_info().unbox();        
        assert(hash_lock == tx_info.transaction_hash, 'Lock not acquired');
        self.atomic_taker_info.write((0, (0,0)));
    }


    fn assert_slippage(self: @ContractState, taker_hash:felt252, max_spend:u256, min_receive:u256) {
        let mut base_trade = ILayerAkiraBaseExecutorDispatcher{contract_address:self.base_executor_address.read()};
        let fill_info = base_trade.get_order_info(taker_hash);
        let (spend, received) = if fill_info.is_sell_side {(fill_info.filled_base_amount, fill_info.filled_quote_amount)}
                                      else {(fill_info.filled_quote_amount,fill_info.filled_base_amount)};
        assert(max_spend == 0 || spend <= max_spend, 'Failed to max spend');
        assert(min_receive == 0 || received >= min_receive, 'Failed to min receive');
    }

    fn buildSOR(self: @ContractState, orchestrate_order:super::SimpleOrder, 
                path:Array<super::SimpleOrder>, router_signature:(felt252, felt252), details:super::SORDetails) ->super::SOR {
            // building sor that is stored in memory
            // creates inplace lead order from simple orchestrate_order
            // flatten path and store in sor order<i> variables in sor since cant store vectors in contract

            let (zero_trade_fee, zero_router_fee, zero_integrator_fee) = getZeroFees(self, details.trade_fee.recipient, details.router_fee.recipient, details.integrator_fee.recipient);
                        
            assert(!(details.min_receive_amount > 0 && details.max_spend_amount > 0), 'Both cant be defined');
            // TODO:
            let full_fill_only = details.max_spend_amount == 0; // if client wants to sell exact -> full_fill_only set to True
            // build lead order inplace
            let lead = Order{maker:get_caller_address(), qty:details.lead_qty, price:orchestrate_order.price, ticker:orchestrate_order.ticker,
                salt:details.salt, source: details.source, sign_scheme: details.sign_scheme, 
                    fee: super::OrderFee{
                        trade_fee:  if details.apply_to_receipt_amount {zero_trade_fee} else {details.trade_fee}, 
                        router_fee: if details.apply_to_receipt_amount {zero_router_fee} else {details.router_fee}, 
                        apply_to_receipt_amount:details.apply_to_receipt_amount,
                        integrator_fee: if details.apply_to_receipt_amount {zero_integrator_fee} else {details.integrator_fee}, 
                        gas_fee: details.gas_fee
                    },
                flags: super::OrderFlags{ full_fill_only, best_level_only: false, post_only: false, is_sell_side: orchestrate_order.is_sell_side,
                    is_market_order: true, to_ecosystem_book: details.to_ecosystem_book, external_funds: details.external_funds
                },
                constraints: super::Constraints{
                    // duration 1 -> should be executed instantly
                    number_of_swaps_allowed: details.number_of_swaps_allowed, duration_valid: details.duration_valid, created_at:details.created_at, 
                    stp: super::TakerSelfTradePreventionMode::NONE, 
                    nonce: details.nonce, min_receive_amount: 0, router_signer: details.router_signer
                }
            };
            
            // cant store array in cairo so we rather limit path size and store in variables
            // note that last order defined always and replace some of the order<i>
            let (sz, none) = (path.len(), Option::None);
            let order0 = if (sz > 1) {Option::Some(*path.at(0))} else {none};
            let order1 = if (sz > 2) {Option::Some(*path.at(1))} else {none};
            let last = *path.at(sz - 1);
            // calc upper for gas swaps
            
            let begin_spend_token = lead.spend_token();
            let end_receive_token = last.receive_token();
            
            let gas_coin = lead.fee.gas_fee.fee_token;
            
            // check no loop
            assert(begin_spend_token != end_receive_token, 'No loops allowed');
            
            // charge for gas at very first orders or very last
            let apply_gas_in_first_trade = begin_spend_token == gas_coin || end_receive_token != gas_coin;
            
            let new_sor = super::SOR{lead, order0, order1, last_order:last,
            router_signature_lead: router_signature, allow_nonatomic_processing:details.allow_nonatomic, 
            router_fee:details.router_fee, trade_fee: details.trade_fee, apply_gas_in_first_trade, path_len: path.len().try_into().unwrap(),
            trades_max:details.number_of_swaps_allowed.into(), min_receive_amount:details.min_receive_amount, max_spend_amount:details.max_spend_amount,
            last_qty:details.last_qty,
            apply_to_receipt_amount: details.apply_to_receipt_amount,
            integrator_fee:details.integrator_fee,
    
            };
            return new_sor;
        }

        fn getTradeAndRouterFees(self: @ContractState, sor:super::SOR, non_zero_fees:bool) -> (super::FixedFee, super::FixedFee, super::FixedFee) {
            if !non_zero_fees {return getZeroFees(self, sor.lead.fee.trade_fee.recipient, sor.lead.fee.router_fee.recipient,  sor.lead.fee.integrator_fee.recipient);}
            return (sor.trade_fee, sor.router_fee, sor.integrator_fee);
        }

        fn getZeroFees(self: @ContractState, exchange:ContractAddress, router:ContractAddress, integrator:ContractAddress) -> (super::FixedFee, super::FixedFee, super::FixedFee) {
            let zero_trade_fee = super::FixedFee{recipient:exchange, maker_pbips:0, taker_pbips:0};
            let zero_router_fee = super::FixedFee{recipient:router, maker_pbips:0, taker_pbips:0};
            let zero_integrator_fee = super::FixedFee{recipient:integrator, maker_pbips:0, taker_pbips:0};
            return (zero_trade_fee, zero_router_fee, zero_integrator_fee);
        }


        fn buildInplaceTakerOrder(self: @ContractState, minimal_order:super::SimpleOrder, lead: Order, 
                trade_fee:super::FixedFee, router_fee: super::FixedFee, integrator_fee:super::FixedFee, previous_fill_amount_qty:u256, 
                    lead_taker_hash:felt252, overwrite_qty:Option<super::Quantity>, apply_to_receipt_amount:bool) -> Order {
            // build inplace taker order given lead order and minimal info for new order
            let qty = if !overwrite_qty.is_some() {
                let base_qty =  if minimal_order.is_sell_side {previous_fill_amount_qty + 1} else {0};
                let quote_qty = if !minimal_order.is_sell_side {previous_fill_amount_qty + 1} else {0};
                super::Quantity{base_asset:minimal_order.base_asset, base_qty, quote_qty}
            } else {overwrite_qty.unwrap()};
            Order{maker:lead.maker, qty, price:minimal_order.price, ticker:minimal_order.ticker,
                salt:lead_taker_hash, source: lead.source, sign_scheme: lead.sign_scheme, fee: super::OrderFee{trade_fee, router_fee, gas_fee: lead.fee.gas_fee, integrator_fee, apply_to_receipt_amount},
                flags: super::OrderFlags{ full_fill_only: overwrite_qty.is_none(), best_level_only: false, post_only: false, is_sell_side: minimal_order.is_sell_side,
                    is_market_order: true, to_ecosystem_book: lead.flags.to_ecosystem_book, external_funds: false
                },
                constraints: super::Constraints{
                    number_of_swaps_allowed: lead.constraints.number_of_swaps_allowed, duration_valid: lead.constraints.duration_valid, created_at: lead.constraints.created_at, 
                    stp: lead.constraints.stp, nonce: lead.constraints.nonce, min_receive_amount: 0, router_signer: lead.constraints.router_signer
                }
            }
        }

        fn apply(ref self: ContractState, lead_order:Order, option_order: Option<super::SimpleOrder>,
                            trade_fee:super::FixedFee, router_fee: super::FixedFee, integrator_fee:super::FixedFee, ptr:u32, offset:u32,
                            makers_orders:Span<(SignedOrder,u256)>, 
                            total_amount_matched_and_len:Span<(u256, u8)>, succ:bool, gas_trades_to_pay:u16,
                            fee_recipient:ContractAddress, transfer_taker_recieve_back:bool, lead_taker_hash:felt252, overwrite_qty: Option<super::Quantity>,
                            apply_to_receipt_amount:bool, gas_ctx:GasContext) -> (u32, u32, felt252) {
            // Depending on succ, either punish or settle trades for the option order and return an new offset and new ptr 
            // where offset for makers order slicing and ptr index of processing order
            //  inplace builds intermediary order from lead_order and supplied fees
            //  Params:
            //      lead_order: lead order that orchestrate sor
            //      option_order: ongoing intermediary order to be filled/or punished
            //      trade_fee: define trade fee for an option order
            //      router_fee: define trade fee for an option order
            //      ptr: points which orders should be taken to be processed from sor
            //      offset: points to an offset in mm orders where right orders start to match against
            //      total_amount_matched_and_len
            //      ...
            //      succ: if order should be settled or marked as failed
            //      
            let mut base_trade = ILayerAkiraBaseExecutorDispatcher{contract_address:self.base_executor_address.read()};

            if option_order.is_some() {
                    let (amount_spent, swaps) = *total_amount_matched_and_len.at(ptr);
                    let order = buildInplaceTakerOrder(@self, option_order.unwrap(), lead_order, trade_fee, router_fee, integrator_fee, amount_spent, lead_taker_hash, overwrite_qty, apply_to_receipt_amount);
                    // TODO: likely need not to calculate message hash?? cause expensive and no point
                    let taker_hash = base_trade.get_order_hash(order);
                    let as_taker_completed = true;
                    if succ {
                        let (accum_base, accum_quote) = base_trade.apply_trades(order, makers_orders.slice(offset, swaps.try_into().unwrap()),
                                    taker_hash, as_taker_completed);
                        let (taker_received, spent) = if order.flags.is_sell_side { (accum_quote, accum_base) } else {(accum_base, accum_quote)};
                            base_trade.finalize_router_taker(order, taker_hash, taker_received, 0, gas_trades_to_pay, spent, transfer_taker_recieve_back, false, gas_ctx); 
                        
                    } else {
                        base_trade.apply_punishment(order, makers_orders.slice(offset, swaps.try_into().unwrap()),
                                taker_hash, as_taker_completed, gas_ctx);

                    }
                    return (ptr + 1, offset + swaps.try_into().unwrap(),  taker_hash);
                }
            return (ptr, offset, 0.try_into().unwrap());
        }
}