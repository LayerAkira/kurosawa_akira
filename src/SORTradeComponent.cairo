



use kurosawa_akira::Order::{SignedOrder,Order,SimpleOrder,get_gas_fee_and_coin, OrderTradeInfo, OrderFee, FixedFee,GasFee, OrderFlags, Constraints,
            get_feeable_qty,get_limit_px, do_taker_price_checks, do_maker_checks, get_available_base_qty, generic_taker_check,generic_common_check,TakerSelfTradePreventionMode};
use starknet::{ContractAddress};
    
#[starknet::interface]
trait ISORTradeLogic<TContractState> {
    
}


// internal structure used for storing client bulk order, up to 5 orders
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Batch {
    lead:Order,
    order0:core::option::Option<SimpleOrder>,
    order1:core::option::Option<SimpleOrder>,
    order2:core::option::Option<SimpleOrder>,
	order3:core::option::Option<SimpleOrder>,
	last_order: SimpleOrder, // enforce explcitly limit to avoid storing list since list expensive in cairo
	router_signature_lead:(felt252,felt252),
	allow_partial_processing:bool,
	trade_fee: FixedFee,
    router_fee:FixedFee,
    apply_gas_in_first_trade: bool, // gas charged in beg or end leg
    path_len:u8
}
#[derive(Copy, Drop, Serde)]
struct BulkDetails { // details supplied with sor bulk orders
    trade_fee:FixedFee, // same as in Order
    router_fee:FixedFee,// same as in Order
    gas_fee: GasFee,// same as in Order
    created_at:u32, // same as in Order
    source:felt252, // same as in Order
    allow_partial:bool, // should it be performed atomically or can be split; for large orders might work only splitting due calldata limit sz
    to_ecosystem_book:bool, // same as in Order
    nonce:u32, // same as in Order
    external_funds:bool, // same as in Order
    router_signer:ContractAddress, // same as in Order
    salt:felt252, // same as in Order
    sign_scheme:felt252, // same as in Order
    // TODO: for now it is rather fingerprints; not validated inside smart contract; only makes sense for the external; external caller can check
    // can be validated in outer calls outside of sor trade component
    min_recieve_amount:u256, // for end leg
    max_spend_amount: u256 // for begining leg
}

#[starknet::component]
mod sor_trade_component {
    use starknet::{get_contract_address, ContractAddress, get_caller_address, get_tx_info, get_block_timestamp};
    use super::{SignedOrder, Order};
    use kurosawa_akira::BaseTradeComponent::base_trade_component as  base_trade_component;
    use base_trade_component::InternalBaseOrderTradable;
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl, SNIP12MetadataImpl};
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcherTrait, ILayerAkiraCoreDispatcher};
    
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}


    #[storage]
    struct Storage {
        atomic_taker_info:(felt252, (felt252, felt252)), // hash lock, router sign
        scheduled_taker_order: Order,
        order_hash_to_batch:starknet::storage::Map::<felt252, super::Batch>,
        batch_to_ptr:starknet::storage::Map::<felt252, (u8,bool)>, // index and is failed batch
        atomic_batch:super::Batch,
        core_address:ContractAddress
    }






    #[embeddable_as(SORTradable)]
    impl SOROrderTradableImpl<TContractState, 
    +HasComponent<TContractState>,
    impl BaseTrade:base_trade_component::HasComponent<TContractState>,
    +Drop<TContractState>> of super::ISORTradeLogic<ComponentState<TContractState>> {}

     #[generate_trait]
    impl InternalSORTradableImpl<TContractState, +HasComponent<TContractState>, +Drop<TContractState> ,
        impl BaseTrade:base_trade_component::HasComponent<TContractState> > of InternalSORTradable<TContractState> {

        fn placeTakerOrder(ref self: ComponentState<TContractState>, order: Order, router_sign: (felt252,felt252)) {
            let (hash_lock, _) = self.atomic_taker_info.read();
            assert(hash_lock == 0, 'Lock already acquired');
            assert(order.maker == get_caller_address(), 'Maker must be caller');
            
            let tx_info = get_tx_info().unbox();
            self.atomic_taker_info.write((tx_info.transaction_hash, router_sign));
            self.scheduled_taker_order.write(order);
        }


        fn fullfillTakerOrder(ref self: ComponentState<TContractState>, mut maker_orders:Array<(SignedOrder,u256)>,
                        total_amount_matched:u256, gas_steps:u32, gas_price:u256) {
            let (hash_lock, router_signature) = self.atomic_taker_info.read();            
            let tx_info = get_tx_info().unbox();
            
            assert(hash_lock == tx_info.transaction_hash, 'Lock not acquired');

            let mut base_trade = get_dep_component_mut!(ref self, BaseTrade);
            base_trade.apply_single_taker(
                SignedOrder{order:self.scheduled_taker_order.read(), sign: array![].span(), router_sign:router_signature},
                maker_orders.span(), total_amount_matched, gas_price, gas_steps, true, true, maker_orders.len().try_into().unwrap(), true, true);
            // release lock
            self.atomic_taker_info.write((0, (0,0)));
        }

		fn placeBatchOrder(ref self: ComponentState<TContractState>, orchestrate_order:super::SimpleOrder, 
                path:Array<super::SimpleOrder>, router_signature:(felt252, felt252), details:super::BulkDetails){
            // Path is only a line:  SHIBA -> STRK -> ETH -> WstETH
            // Path is limited to 5 edges, kinda synthethic order mathcing
            // if bulk is atomic -> need to acquire lock
            // First trade is defined by external_funds parameter; remaining in safe determinstic ctx (external_funds==False)
            // First trade incur router & trade fee and 0 fees for rest iff fixed fee apply_to_receipt == False
            // last trade incur router & trade fee and 0 fees for rest iff fixed fee apply_to_receipt == True
            // gas for all trades paid only at first trade iff payment token  == spending token or payment token (1)  != last trade receive token (2);
            // gas for all trades paid only at last trade  iff payment token  == last trade receive token
            // gas must be tferred beforehand iff (1) & (2) even if (2) is in path sequence
            // assumed that rather used for external funds since for internal can be combined on offchain side

		    if (!details.allow_partial) { self.acquireLock(router_signature);}
            let (caller, sz) = (get_caller_address(), path.len());
            assert(sz != 0, 'use non bulk');
            assert(sz <= 5, 'path is too long');
            assert(details.trade_fee.apply_to_receipt_amount == details.router_fee.apply_to_receipt_amount, 'incorrect apply_to_receipt flag');

            let zero_trade_fee = super::FixedFee{recipient:details.trade_fee.recipient, maker_pbips:0, 
                        taker_pbips:0, apply_to_receipt_amount:details.trade_fee.apply_to_receipt_amount};
            let zero_router_fee = super::FixedFee{recipient:details.router_fee.recipient, maker_pbips:0, 
                        taker_pbips:0, apply_to_receipt_amount:details.trade_fee.apply_to_receipt_amount};

            // build lead order inplace
            let lead = Order{maker:caller, qty:orchestrate_order.qty, price:orchestrate_order.price, ticker:orchestrate_order.ticker,
                salt:details.salt, source: details.source, sign_scheme: details.sign_scheme, 
                    fee: super::OrderFee{
                        trade_fee:  if details.trade_fee.apply_to_receipt_amount {zero_trade_fee} else {details.trade_fee}, 
                        router_fee: if details.trade_fee.apply_to_receipt_amount {zero_router_fee} else {details.router_fee}, 
                        gas_fee: details.gas_fee
                    },
                flags: super::OrderFlags{ full_fill_only: false, best_level_only: false, post_only: false, is_sell_side: orchestrate_order.is_sell_side,
                    is_market_order: true, to_ecosystem_book: details.to_ecosystem_book, external_funds: details.external_funds
                },
                constraints: super::Constraints{
                    // duration 1 -> should be executed instantly
                    number_of_swaps_allowed: orchestrate_order.number_of_swaps_allowed, duration_valid: 1, created_at:details.created_at, 
                    stp: super::TakerSelfTradePreventionMode::NONE, 
                    nonce: details.nonce, min_receive_amount: 0, router_signer: details.router_signer
                }
            };
            
            // cant store array in cairo so we rather limit path size and store in variables
            let none = core::option::Option::None;
            let order0 = if (sz > 1) {core::option::Option::Some(*path.at(0))} else {none};
            let order1 = if (sz > 2) {core::option::Option::Some(*path.at(1))} else {none};
            let order2 = if (sz > 3) {core::option::Option::Some(*path.at(2))} else {none};
            let order3 = if (sz > 4) {core::option::Option::Some(*path.at(3))} else {none};
            let last = *path.at(sz - 1);

            let begin_spend_token = if lead.flags.is_sell_side {let (b,_) = lead.ticker;b} else {let (_,q) = lead.ticker; q};
            let end_receive_token = if !last.is_sell_side {let (b,_) = last.ticker;b} else {let (_, q) = last.ticker; q};
            let gas_coin = lead.fee.gas_fee.fee_token;
            // charge for gas at very first orders or very last
            let apply_gas_in_first_trade = begin_spend_token == gas_coin || end_receive_token != gas_coin;
            



            let new_batch = super::Batch{lead,  order0, order1, order2, order3, last_order:last,
                router_signature_lead: router_signature, allow_partial_processing:details.allow_partial, 
                router_fee:details.router_fee, trade_fee: details.trade_fee, apply_gas_in_first_trade, path_len: path.len().try_into().unwrap(),
            };
            if (details.allow_partial){
                let key = lead.get_message_hash(lead.maker); 
                let batch = self.order_hash_to_batch.read(key);
                assert(batch.lead.maker.try_into().unwrap() == 0, 'Batch already existed');
                self.order_hash_to_batch.write(key, new_batch);
            } else { self.atomic_batch.write(new_batch);}
        }

        fn fulfillBatchAtomic(ref self: ComponentState<TContractState>, makers_orders:Array<(SignedOrder,u256)>,
                        total_amount_matched_and_len:Array<(u256, u8)>, gas_steps:u32, gas_price:u256) {
            
            let mut base_trade = get_dep_component_mut!(ref self, BaseTrade);
            let batch = self.atomic_batch.read();
            let ((first, last), (total_amount_matched, swaps)) = ((batch.lead, batch.last_order), *total_amount_matched_and_len.at(0));
            
            let span_amount_matched = total_amount_matched_and_len.span().slice(1, total_amount_matched_and_len.len() - 1); 
            let (makers_span, fee_recipient) = (makers_orders.span(), first.fee.trade_fee.recipient);
            
            let total_trades = makers_orders.len().try_into().unwrap();
            // charge for gas at very first or
            // responsibility of layer akira backend if on last order 
            // if some intermediary force to check if have enough; gas charged from the begining, avoid use receive side  
            let (gas_trades, last_trades) = if batch.apply_gas_in_first_trade {(total_trades,0)} else {(0,total_trades)};
            let (skip_taker_validation, allow_charge_gas_on_receipt) = (false, false);
            let succ = base_trade.apply_single_taker(
                SignedOrder{order:first, sign: array![].span(), router_sign:batch.router_signature_lead},
                makers_span.slice(0, swaps.try_into().unwrap()), total_amount_matched, gas_price, gas_steps, true, 
                skip_taker_validation, gas_trades, false, allow_charge_gas_on_receipt);
                        

            let zero_trade_fee = super::FixedFee{recipient:first.fee.trade_fee.recipient, maker_pbips:0, 
                        taker_pbips:0, apply_to_receipt_amount:first.fee.trade_fee.apply_to_receipt_amount};
            let zero_router_fee = super::FixedFee{recipient:first.fee.router_fee.recipient, maker_pbips:0, 
                        taker_pbips:0, apply_to_receipt_amount:first.fee.trade_fee.apply_to_receipt_amount};

            let (mut ptr, mut offset) = (0, swaps.try_into().unwrap());
            let tfer_taker_recieve_back = false;
            let (ptr1, offset1) = self.apply(first, batch.order0, zero_trade_fee, zero_router_fee, ptr, offset, makers_span, span_amount_matched, gas_price, gas_steps, succ, 0, fee_recipient, tfer_taker_recieve_back);
            ptr = ptr1; offset = offset1;
            let (ptr1, offset1) = self.apply(first, batch.order1, zero_trade_fee, zero_router_fee, ptr, offset, makers_span, span_amount_matched, gas_price, gas_steps, succ, 0, fee_recipient, tfer_taker_recieve_back);
            ptr = ptr1; offset = offset1;
            let (ptr1, offset1) = self.apply(first, batch.order2, zero_trade_fee, zero_router_fee, ptr, offset, makers_span, span_amount_matched, gas_price, gas_steps, succ, 0, fee_recipient, tfer_taker_recieve_back);
            ptr = ptr1; offset = offset1;
            let (ptr1, offset1) = self.apply(first, batch.order3, zero_trade_fee, zero_router_fee, ptr, offset, makers_span, span_amount_matched, gas_price, gas_steps, succ, 0, fee_recipient, tfer_taker_recieve_back);
            ptr = ptr1; offset = offset1;
            let tfer_back_received =  first.flags.external_funds;
            let (ptr1, offset1) = self.apply(first, core::option::Option::Some(last), 
                if batch.trade_fee.apply_to_receipt_amount {batch.trade_fee} else {zero_trade_fee}, 
                if batch.trade_fee.apply_to_receipt_amount {batch.router_fee} else {zero_router_fee}, 
                    ptr, offset, makers_span, span_amount_matched, gas_price, gas_steps, succ, last_trades, fee_recipient, tfer_back_received);
            ptr = ptr1; offset = offset1;
            assert(offset == makers_orders.len(),'Mismatch orders count');
            self.releaseLock(true);
        }


        fn fulfillBatchStepFirst(ref self: ComponentState<TContractState>,batch_id:felt252, makers_orders:Array<(SignedOrder,u256)>,
                        total_amount_matched:u256, gas_steps:u32, gas_price:u256, total_trades:u16) {
            let batch = self.order_hash_to_batch.read(batch_id);
            let (head, _) = self.batch_to_ptr.read(batch_id);
            assert(head == 0, 'batch already processed');
            assert(batch.lead.maker != 0x0.try_into().unwrap(), 'batch not initialized');
            assert(batch.allow_partial_processing, 'this batch atomic only');

            let mut base_trade = get_dep_component_mut!(ref self, BaseTrade);
            let (skip_taker_validation, allow_charge_gas_on_receipt) = (false, false);
            let (gas_trades, _) = if batch.apply_gas_in_first_trade {(total_trades,0)} else {(0,total_trades)};
            
            let succ = base_trade.apply_single_taker(
                SignedOrder{order:batch.lead, sign: array![].span(), router_sign:batch.router_signature_lead},
                makers_orders.span(), total_amount_matched, gas_price, gas_steps, true, 
                skip_taker_validation, gas_trades, false, allow_charge_gas_on_receipt);
            self.batch_to_ptr.write(batch_id, (1, !succ));
        }

        fn fulfillBatchStepI(ref self: ComponentState<TContractState>,batch_id:felt252, makers_orders:Array<(SignedOrder,u256)>,
                    total_amount_matched:u256, gas_steps:u32, gas_price:u256, total_trades:u16) {
            let batch = self.order_hash_to_batch.read(batch_id);
            let (head, failed) = self.batch_to_ptr.read(batch_id);
            assert(head != 0, 'batch not lead processed');
            assert(head - 1 < batch.path_len, 'batch processed');
            let succ = !failed;
            let fee_recipient = batch.lead.fee.trade_fee.recipient;
            let zero_trade_fee = super::FixedFee{recipient:batch.lead.fee.trade_fee.recipient, maker_pbips:0, 
                        taker_pbips:0, apply_to_receipt_amount:batch.lead.fee.trade_fee.apply_to_receipt_amount};
                let zero_router_fee = super::FixedFee{recipient:batch.lead.fee.router_fee.recipient, maker_pbips:0, 
                            taker_pbips:0, apply_to_receipt_amount:batch.lead.fee.trade_fee.apply_to_receipt_amount};
            let matched = array![(total_amount_matched, makers_orders.len().try_into().unwrap())].span();
            if (head == batch.path_len) {
                let tfer_taker_recieve_back = false;
                let order = if (head == 1) {batch.order0} else if (head == 2) {batch.order1} else if (head == 2) {batch.order2} else {batch.order3};
                self.apply(batch.lead, order, zero_trade_fee, zero_router_fee, 0, 0, makers_orders.span(), matched, gas_price, gas_steps, succ, 0, fee_recipient, tfer_taker_recieve_back);
            } else  {               
                let (_, last_trades) = if batch.apply_gas_in_first_trade {(total_trades, 0)} else {(0, total_trades)};
                let last = batch.last_order;            
                self.apply(batch.lead, core::option::Option::Some(last), 
                if batch.trade_fee.apply_to_receipt_amount {batch.trade_fee} else {zero_trade_fee}, 
                if batch.trade_fee.apply_to_receipt_amount {batch.router_fee} else {zero_router_fee}, 
                    0, 0, makers_orders.span(), matched , gas_price, gas_steps, succ, last_trades, fee_recipient, batch.lead.flags.external_funds);
            }
            self.batch_to_ptr.write(batch_id, (head + 1, failed));            
        }

        
        fn buildInplaceTakerOrder(self: @ComponentState<TContractState>, minimal_order:super::SimpleOrder, lead: Order, 
                trade_fee:super::FixedFee, router_fee: super::FixedFee) -> Order {
            // build inplace taker order given lead order and minimal info for new order
            let cur_time = get_block_timestamp();
            
            Order{maker:lead.maker, qty:minimal_order.qty, price:minimal_order.price, ticker:minimal_order.ticker,
                salt:0, source: lead.source, sign_scheme: lead.sign_scheme, fee: super::OrderFee{trade_fee, router_fee, gas_fee: lead.fee.gas_fee},
                flags: super::OrderFlags{ full_fill_only: false, best_level_only: false, post_only: false, is_sell_side: minimal_order.is_sell_side,
                    is_market_order: true, to_ecosystem_book: lead.flags.to_ecosystem_book, external_funds: false
                },
                constraints: super::Constraints{
                    number_of_swaps_allowed: minimal_order.number_of_swaps_allowed, duration_valid: 1, created_at: cur_time.try_into().unwrap(), 
                    stp: lead.constraints.stp, nonce: lead.constraints.nonce, min_receive_amount: 0, router_signer: lead.constraints.router_signer
                }
            }
        }

        fn apply(ref self: ComponentState<TContractState>, lead_order:Order, option_order: core::option::Option<super::SimpleOrder>,
                            trade_fee:super::FixedFee,router_fee: super::FixedFee, ptr:u32, offset:u32,
                            makers_orders:Span<(SignedOrder,u256)>, 
                            total_amount_matched_and_len:Span<(u256, u8)>, gas_price:u256, gas_steps:u32, succ:bool, gas_trades_to_pay:u16,
                            fee_recipient:ContractAddress, transfer_taker_recieve_back:bool) -> (u32,u32) {
            let mut base_trade = get_dep_component_mut!(ref self, BaseTrade);
            if option_order.is_some() {
                    let order = self.buildInplaceTakerOrder(option_order.unwrap(), lead_order, trade_fee, router_fee);
                    // TODO: likely need not to calculate message hash?? cause expensive and no point
                    let taker_hash = order.get_message_hash(order.maker);
                    let (_, swaps) = *total_amount_matched_and_len.at(ptr);
                    if succ {
                        let (accum_base, accum_quote) = base_trade.apply_trades(order, makers_orders.slice(offset, swaps.try_into().unwrap()), lead_order.fee.trade_fee.recipient, 
                                    taker_hash, gas_price, gas_steps, true);
                        if transfer_taker_recieve_back {
                            let (taker_received, spent) = if order.flags.is_sell_side { (accum_quote, accum_base) } else {(accum_base, accum_quote)};
                            base_trade.finalize_router_taker(order, taker_hash, taker_received, 0, gas_price, 
                                gas_trades_to_pay, gas_steps, spent, fee_recipient, transfer_taker_recieve_back, false); 
                        }
                    } else {
                        base_trade.apply_punishment(order, makers_orders.slice(offset, swaps.try_into().unwrap()), lead_order.fee.trade_fee.recipient, 
                        taker_hash, gas_price, gas_steps,true);

                    }
                    return (offset + swaps.try_into().unwrap(), ptr + 1);
                }
            return (offset, ptr);
        }

        fn acquireLock(ref self:ComponentState<TContractState>, router_sign:(felt252,felt252)) {
            let (hash_lock, _) = self.atomic_taker_info.read();
            assert(hash_lock == 0, 'Lock already acquired');       
            let tx_info = get_tx_info().unbox();
            self.atomic_taker_info.write((tx_info.transaction_hash, router_sign));
        }

        fn releaseLock(ref self:ComponentState<TContractState>,same_tx:bool){
            if (same_tx) {
                let (hash_lock, _) = self.atomic_taker_info.read();            
                let tx_info = get_tx_info().unbox();        
                assert(hash_lock == tx_info.transaction_hash, 'Lock not acquired');
            }
            self.atomic_taker_info.write((0, (0,0)));
        }
    }
}