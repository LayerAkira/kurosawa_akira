use core::option::OptionTrait;
use core::traits::TryInto;
use starknet::{
    contract_address_const, get_tx_info, get_caller_address, testing::set_caller_address,ContractAddress
};
use pedersen::PedersenTrait;
use hash::{HashStateTrait, HashStateExTrait};
use super::IOffchainMessage::{IOffchainMessageHash,IStructHash,SNIP12Metadata};
use super::V0OffchainMessage::{StructHashU256Impl, OffchainMessageHashImpl};
use kurosawa_akira::WithdrawComponent::{Withdraw};
use kurosawa_akira::Order::{Order,FixedFee,GasFee,TakerSelfTradePreventionMode, Quantity, Constraints, OrderFlags,OrderFee};
use kurosawa_akira::NonceComponent::{IncreaseNonce};    


impl SNIP12MetadataImpl of SNIP12Metadata {
    fn name() -> felt252 { 'LayerAkira Exchange'}
    fn version() -> felt252 { '0.0.1'}
}



// const GASFEE_TYPE_HASH: felt252 = selector!("GasFee(gas_per_action:felt,fee_token:felt,max_gas_price:u256,r0:u256,r1:u256)u256(low:felt,high:felt)");
const GASFEE_TYPE_HASH: felt252 = 0x1A39CA962D62DDE02988F6E3C3D248A70555CE48D84681FC67115E8C25F5927;
impl GasFeeHashImpl of IStructHash<GasFee> {
    
    fn hash_struct(self: @GasFee) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(GASFEE_TYPE_HASH);
        state = state.update_with(*self.gas_per_action);
        state = state.update_with(*self.fee_token);
        state = state.update_with(self.max_gas_price.hash_struct());
        let (r0,r1) = self.conversion_rate;
        state = state.update_with(r0.hash_struct());
        state = state.update_with(r1.hash_struct());
        state = state.update_with(6);
        state.finalize()
    }
}

//  ORDER


// const FIXEDFEE_TYPE_HASH: felt252 = selector!("FixedFee(recipient:felt,maker_pbips:felt,taker_pbips:felt)");
const FIXEDFEE_TYPE_HASH: felt252 = 0x8C6A6C4FC175EE3AC9212E86D8D6DD1326181DC94AC44A14F400B3F37E5A3F;
impl FixedFeeHashImpl of IStructHash<FixedFee> {
    fn hash_struct(self: @FixedFee) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(FIXEDFEE_TYPE_HASH);
        state = state.update_with(*self);
        state = state.update_with(4);
        state.finalize()
    }
}


// const ORDERFEE_TYPE_HASH: felt252 = selector!("OrderFee(trade_fee:FixedFee,router_fee:FixedFee,gas_fee:GasFee)FixedFee(recipient:felt,maker_pbips:felt,taker_pbips:felt)GasFee(gas_per_action:felt,fee_token:felt,max_gas_price:u256,r0:u256,r1:u256)u256(low:felt,high:felt)");
const ORDERFEE_TYPE_HASH: felt252 = 0x2b94b7482e2347fbe1c6c86b9c269ce2f4a56db0da275851870c30dfec964bd;
impl OrderFeeHashImpl of IStructHash<OrderFee> {
    fn hash_struct(self: @OrderFee) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(ORDERFEE_TYPE_HASH);
        state = state.update_with(self.trade_fee.hash_struct());
        state = state.update_with(self.router_fee.hash_struct());
        state = state.update_with(self.gas_fee.hash_struct());
        state = state.update_with(4);
        state.finalize()
    }
}

// const ORDERFLAGS_TYPE_HASH: felt252 = selector!("OrderFlags(full_fill_only:bool,best_level_only:bool,post_only:bool,is_sell_side:bool,is_market_order:bool,to_ecosystem_book:bool,external_funds:bool)");
const ORDERFLAGS_TYPE_HASH: felt252 =  0xf4acda9e8bbf75928080965997bf8f485abcc2113a9d8b08fc2a30249988e3;
impl OrderFlagsHashImpl of IStructHash<OrderFlags> {
    fn hash_struct(self: @OrderFlags) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(ORDERFLAGS_TYPE_HASH);
        state = state.update_with(*self);
        state = state.update_with(8);
        state.finalize()
    }
}


// const QUANTITY_TYPE_HASH: felt252 = selector!("Quantity(base_qty:u256,quote_qty:u256,base_asset:u256)u256(low:felt,high:felt)");
const QUANTITY_TYPE_HASH: felt252 =  0x86a677a4608ab4c497f6157ac95210589a82883be0665f34e7cbf80c65bd5d;
impl QuantityHashImpl of IStructHash<Quantity> {
    fn hash_struct(self: @Quantity) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(QUANTITY_TYPE_HASH);
        state = state.update_with(self.base_qty.hash_struct());
        state = state.update_with(self.quote_qty.hash_struct());
        state = state.update_with(self.base_asset.hash_struct());
        state = state.update_with(4);
        state.finalize()
    }
}

// const CONSTRAINTS_TYPE_HASH: felt252 = selector!("Constraints(number_of_swaps_allowed:felt,duration_valid:felt,created_at:felt,stp:felt,nonce:felt,min_receive_amount:u256,router_signer:felt)u256(low:felt,high:felt)");
const CONSTRAINTS_TYPE_HASH: felt252 = 0x15AD6B6E2857A7B2A494F79AD1051D9BE921C5B5A8AF916675B7A4B5FECE5E8;
impl ConstraintsHashImpl of IStructHash<Constraints> {
    fn hash_struct(self: @Constraints) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(CONSTRAINTS_TYPE_HASH);
        state = state.update_with(*self.number_of_swaps_allowed);
        state = state.update_with(*self.duration_valid);
        state = state.update_with(*self.created_at);
        state = match self.stp {
            TakerSelfTradePreventionMode::NONE => { state.update_with(0x0)},
            TakerSelfTradePreventionMode::EXPIRE_TAKER => {state.update_with(0x1)},
            TakerSelfTradePreventionMode::EXPIRE_MAKER => {state.update_with(0x2)},
            TakerSelfTradePreventionMode::EXPIRE_BOTH => { state.update_with(0x3)}
        };
        state = state.update_with(*self.nonce);
        state = state.update_with(self.min_receive_amount.hash_struct());
        state = state.update_with(*self.router_signer);
        state = state.update_with(8);
        state.finalize()
    }
}

// const ORDER_TYPE_HASH: felt252 = selector!("Order(maker:felt,price:u256,qty:Quantity,base:felt,quote:felt,fee:OrderFee,constraints:Constraints,salt:felt,flags:OrderFlags,version:felt)Constraints(number_of_swaps_allowed:felt,duration_valid:felt,created_at:felt,stp:felt,nonce:felt,min_receive_amount:u256,router_signer:felt)FixedFee(recipient:felt,maker_pbips:felt,taker_pbips:felt)GasFee(gas_per_action:felt,fee_token:felt,max_gas_price:u256,r0:u256,r1:u256)OrderFee(trade_fee:FixedFee,router_fee:FixedFee,gas_fee:GasFee)OrderFlags(full_fill_only:bool,best_level_only:bool,post_only:bool,is_sell_side:bool,is_market_order:bool,to_ecosystem_book:bool,external_funds:bool)Quantity(base_qty:u256,quote_qty:u256,base_asset:u256)u256(low:felt,high:felt)");
const ORDER_TYPE_HASH: felt252 =  0x2800a4673144d776806ab7f91fe2fd92dca29df9d3c40b71976bc99b44436b2;
impl OrderHashImpl of IStructHash<Order> {
    fn hash_struct(self: @Order) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(ORDER_TYPE_HASH);
        state = state.update_with(*self.maker);
        state = state.update_with(self.price.hash_struct());
        state = state.update_with(self.qty.hash_struct());
        let (b,q) = *self.ticker;
        state = state.update_with(b);
        state = state.update_with(q);
        state = state.update_with(self.fee.hash_struct());
        state = state.update_with(self.constraints.hash_struct());
        state = state.update_with(*self.salt);
        state = state.update_with(self.flags.hash_struct());
        state = state.update_with(*self.version);
        state = state.update_with(11);
        state.finalize()
    }
}

// const WITHDRAW_TYPE_HASH: felt252 = 
    // selector!("Withdraw(maker:felt,token:felt,amount:u256,salt:felt,gas_fee:GasFee,receiver:felt)GasFee(gas_per_action:felt,fee_token:felt,max_gas_price:u256,r0:u256,r1:u256)u256(low:felt,high:felt)");
const WITHDRAW_TYPE_HASH: felt252 = 0x466E61BEFD45811F87C6413B093A10F499B8AE9F47A9A12EBAC12A6F2E0F6C;
impl WithdrawHashImpl of IStructHash<Withdraw> {
    fn hash_struct(self: @Withdraw) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(WITHDRAW_TYPE_HASH);
        state = state.update_with(*self.maker);
        state = state.update_with(*self.token);
        state = state.update_with(self.amount.hash_struct());
        state = state.update_with(*self.salt);
        state = state.update_with(self.gas_fee.hash_struct());
        state = state.update_with(*self.receiver);
        state = state.update_with(7);
        state.finalize()
    }
}


// const NONCE_TYPE_HASH: felt252 = 
//     selector!("OnchainCancelAll(maker:felt,new_nonce:felt,gas_fee:GasFee)GasFee(gas_per_action:felt,fee_token:felt,max_gas_price:u256,r0:u256,r1:u256)u256(low:felt,high:felt)");
const NONCE_TYPE_HASH: felt252 = 0x30e4ca37feb850e0b0e8b214381d47f3c50c3adf1e00062ea7ecdfc1f2192f8;
impl IncreaseNonceHashImpl of IStructHash<IncreaseNonce> {
    fn hash_struct(self: @IncreaseNonce) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(NONCE_TYPE_HASH);
        state = state.update_with(*self.maker);
        state = state.update_with(*self.new_nonce);
        state = state.update_with(self.gas_fee.hash_struct());
        state = state.update_with(4);
        state.finalize()
    }
}